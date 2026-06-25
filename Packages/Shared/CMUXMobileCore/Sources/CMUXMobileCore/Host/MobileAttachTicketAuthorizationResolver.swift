import Foundation

/// The scoped-attach-ticket authorization policy for the mobile host data plane.
///
/// Pure compute: it maps a ``CmxAttachTicket`` (plus the workspace/terminal IDs
/// created under its auth token) and a per-method request selection to an
/// optional ``MobileAttachTicketError``. It holds no listener/connection/actor
/// state, performs no network or filesystem I/O, and never touches the app's
/// `Any`-shaped RPC envelope types: the host extracts typed selection inputs from
/// its `MobileHostRPCRequest` and passes them in, and maps the returned
/// ``MobileAttachTicketError`` back onto its `MobileHostRPCError` at the call site.
///
/// This is the ticket-SCOPING gate (does this ticket reach this workspace or
/// terminal). The same-account Stack gate is authoritative for whether a caller
/// may speak the data plane at all (see the host's `authorizationError(for:)`);
/// this resolver only narrows an already-Stack-authorized caller to the
/// workspace/terminal its ticket pins.
///
/// Lifted byte-faithfully from the static `ticketAuthorizationError` /
/// `ticketTerminalAuthorizationError` / `filteredRoutes` / `stringParamSelection`
/// / `containsIgnoredAliasParameters` / `requiresAuthorization` cluster that
/// lived inside `MobileHostService.swift`. Per the refactor conventions the
/// static-only namespace becomes a real value type with instance methods;
/// construct one (`MobileAttachTicketAuthorizationResolver()`) and call it.
public struct MobileAttachTicketAuthorizationResolver: Sendable {
    /// Creates a resolver. Stateless; every instance is interchangeable.
    public init() {}

    /// Whether a method requires same-account authorization before it runs.
    ///
    /// Only the unauthenticated host probe is exempt. `mobile.attach_ticket.create`
    /// mints a bearer credential, so it MUST be authorized: a network caller has no
    /// attach token yet, so it is routed through the same-account Stack Auth token
    /// (the iOS client always sends it for this method). Leaving it exempt would let
    /// any process that can speak the wire protocol self-issue a working ticket and
    /// take over the terminal. The on-Mac QR pairing mints tickets through the local
    /// automation socket (`TerminalController`), not this network path, so it is
    /// unaffected.
    public func requiresAuthorization(method: String) -> Bool {
        switch method {
        case "mobile.host.status":
            return false
        default:
            return true
        }
    }

    /// Narrows `routes` to those matching the requested route id and/or kind.
    ///
    /// An empty/whitespace `routeID` and `routeKind` mean "no filter": all routes
    /// pass. When a filter is present but nothing matches, throws
    /// ``MobileAttachTicketRouteSelectionError/routeUnavailable``.
    public func filteredRoutes(
        _ routes: [CmxAttachRoute],
        routeID: String?,
        routeKind: String?
    ) throws -> [CmxAttachRoute] {
        let normalizedRouteID = routeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRouteKind = routeKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasRouteID = normalizedRouteID?.isEmpty == false
        let hasRouteKind = normalizedRouteKind?.isEmpty == false
        guard hasRouteID || hasRouteKind else {
            return routes
        }

        let filtered = routes.filter { route in
            if hasRouteID, route.id != normalizedRouteID {
                return false
            }
            if hasRouteKind, route.kind.rawValue != normalizedRouteKind {
                return false
            }
            return true
        }
        guard !filtered.isEmpty else {
            throw MobileAttachTicketRouteSelectionError.routeUnavailable
        }
        return filtered
    }

    /// Resolves the per-method ticket-scoping decision for an already-Stack-authorized
    /// request, returning `nil` when the ticket covers the request or a
    /// ``MobileAttachTicketError`` when it does not.
    ///
    /// - Parameters:
    ///   - authorization: the ticket plus the workspace/terminal IDs already created
    ///     under its auth token (those are always reachable regardless of the pin).
    ///   - method: the RPC method name.
    ///   - workspaceSelection: the conflict-resolved `workspace_id` selection.
    ///   - terminalSelection: the conflict-resolved `surface_id`/`terminal_id`/`tab_id`
    ///     selection.
    ///   - hasIgnoredAliasParameters: whether the request carried a `workspaceID` or
    ///     `terminalID` alias key that the handlers ignore (a scoping bypass attempt).
    public func authorizationError(
        authorization: MobileAttachTicketAuthorizationContext,
        method: String,
        workspaceSelection: MobileAttachTicketStringParamSelection,
        terminalSelection: MobileAttachTicketStringParamSelection,
        hasIgnoredAliasParameters: Bool
    ) -> MobileAttachTicketError? {
        if workspaceSelection.hasConflict || terminalSelection.hasConflict {
            return .scoped
        }
        if hasIgnoredAliasParameters {
            return .scoped
        }

        switch method {
        case "mobile.workspace.list", "workspace.list":
            return nil
        case "workspace.create":
            return nil
        case "workspace.group.collapse", "workspace.group.expand":
            // Display-only group state. Keyed by `group_id` (not a workspace or
            // terminal selection), so it is Mac-scoped like the workspace list and
            // not constrained by the ticket's workspace/terminal pin. The Stack
            // same-account gate in `authorizationError` remains authoritative.
            return nil
        case "mobile.terminal.create", "terminal.create":
            return nil
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport",
             "mobile.terminal.scroll", "terminal.scroll":
            return terminalAuthorizationError(
                authorization: authorization,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.events.subscribe", "mobile.events.unsubscribe":
            return nil
        case "mobile.host.status":
            return nil
        default:
            return .scoped
        }
    }

    private func terminalAuthorizationError(
        authorization: MobileAttachTicketAuthorizationContext,
        workspaceSelection: String?,
        terminalSelection: String?
    ) -> MobileAttachTicketError? {
        if let terminalSelection,
           authorization.createdTerminalIDs.contains(terminalSelection) {
            return nil
        }
        if let workspaceSelection,
           authorization.createdWorkspaceIDs.contains(workspaceSelection) {
            return nil
        }

        let ticket = authorization.ticket
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // Allow any workspace/terminal under it.
        if ticketWorkspaceID.isEmpty {
            return nil
        }
        if let workspaceSelection, workspaceSelection != ticketWorkspaceID {
            return .scoped
        }

        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            guard terminalSelection == terminalID else {
                return .scoped
            }
            return nil
        }

        guard workspaceSelection == ticketWorkspaceID else {
            return .scoped
        }
        return nil
    }

    /// Resolves the conflict-aware string selection for `keys` from a request
    /// parameter dictionary.
    ///
    /// Returns the first non-empty trimmed string value among `keys`; if two keys
    /// carry different non-empty values the selection is flagged as conflicting
    /// (a scoping bypass attempt). Non-string values are ignored, matching the
    /// legacy `params[key] as? String` behavior.
    public func stringParamSelection(
        _ params: [String: Any],
        keys: [String]
    ) -> MobileAttachTicketStringParamSelection {
        var selected: String?
        for key in keys {
            if let value = params[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let selected, selected != trimmed {
                        return MobileAttachTicketStringParamSelection(value: selected, hasConflict: true)
                    }
                    selected = selected ?? trimmed
                }
            }
        }
        return MobileAttachTicketStringParamSelection(value: selected, hasConflict: false)
    }

    /// Whether the request carries an alias parameter the handlers ignore.
    ///
    /// `workspaceID`/`terminalID` (camelCase) are not read by any handler, so a
    /// caller that sends them is attempting to slip a selection past the scoping
    /// gate; their presence forces a scoped rejection.
    public func containsIgnoredAliasParameters(_ params: [String: Any]) -> Bool {
        params["workspaceID"] != nil || params["terminalID"] != nil
    }
}

/// The ticket plus the workspace/terminal IDs already created under its auth token.
///
/// A pure `Sendable` snapshot the host hands to
/// ``MobileAttachTicketAuthorizationResolver``. Created resources are always
/// reachable by the ticket regardless of its workspace/terminal pin, so the
/// resolver checks them first.
public struct MobileAttachTicketAuthorizationContext: Sendable {
    /// The attach ticket whose pin scopes the request.
    public let ticket: CmxAttachTicket
    /// Workspace IDs created under the ticket's auth token.
    public let createdWorkspaceIDs: Set<String>
    /// Terminal IDs created under the ticket's auth token.
    public let createdTerminalIDs: Set<String>

    /// Creates an authorization context snapshot.
    public init(
        ticket: CmxAttachTicket,
        createdWorkspaceIDs: Set<String>,
        createdTerminalIDs: Set<String>
    ) {
        self.ticket = ticket
        self.createdWorkspaceIDs = createdWorkspaceIDs
        self.createdTerminalIDs = createdTerminalIDs
    }
}

/// A conflict-aware string selection drawn from a set of request parameter keys.
///
/// `value` is the first non-empty trimmed value found; `hasConflict` is `true`
/// when two of the candidate keys carried different non-empty values (which the
/// resolver treats as a scoping bypass attempt).
public struct MobileAttachTicketStringParamSelection: Sendable, Equatable {
    /// The selected value, or `nil` when no candidate key carried a non-empty value.
    public let value: String?
    /// Whether two candidate keys carried different non-empty values.
    public let hasConflict: Bool

    /// Creates a selection result.
    public init(value: String?, hasConflict: Bool) {
        self.value = value
        self.hasConflict = hasConflict
    }
}

/// A typed ticket-scoping rejection the host maps onto its client-facing RPC error.
///
/// Carries a stable `code` and a default English `message`; the host resolves the
/// localized message at its call site (the package bundle lacks the app's
/// `.xcstrings` keys) and builds its `MobileHostRPCError` from this.
public enum MobileAttachTicketError: Error, Sendable, Equatable {
    /// The attach ticket does not cover the requested workspace or terminal.
    case scoped

    /// The stable client-facing error code.
    public var code: String {
        switch self {
        case .scoped:
            return "forbidden"
        }
    }

    /// The default English message. Localize at the host call site before sending.
    public var defaultMessage: String {
        switch self {
        case .scoped:
            return "Attach ticket is not valid for this workspace or terminal."
        }
    }
}

/// The reasons route selection can fail when minting an attach ticket.
///
/// Thrown by ``MobileAttachTicketAuthorizationResolver/filteredRoutes(_:routeID:routeKind:)``;
/// the host maps it onto its `MobileAttachTicketStoreError.routeUnavailable`.
public enum MobileAttachTicketRouteSelectionError: Error, Sendable, Equatable {
    /// A route id/kind filter was requested but no advertised route matched it.
    case routeUnavailable
}
