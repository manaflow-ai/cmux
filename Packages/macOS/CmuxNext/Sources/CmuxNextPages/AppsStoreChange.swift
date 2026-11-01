public import CmuxNextSettings
public import Foundation

/// One App Store change the person confirms on the native consent card: `cmux.apps.install` (with
/// an optional deploy target, install = deploy + pin) or `cmux.apps.uninstall`.
///
/// The CLI (`cmux apps install|remove`), the palette and MCP build one of these and send it through
/// the App Store's own ``ConfirmingPageProvider``, so every entry point shows the same card and only
/// the person's click makes the call the user's (docs/app-store-platonic-ideal.md P13).
///
/// ```swift
/// let change = AppsStoreChange(kind: .install, app: "manaflow-ai/hello-deploy", deploy: "self-hosted:build-01")
/// let outcome = await change.send(through: provider)
/// ```
public nonisolated struct AppsStoreChange: Sendable, Hashable {
    /// Which change.
    public enum Kind: Sendable, Hashable {
        /// Install the app (and deploy it when ``AppsStoreChange/deploy`` is set).
        case install
        /// Remove the app (its instance, if any, is removed by the supervisor).
        case remove
    }

    /// How the change ended.
    public enum Outcome: Sendable, Hashable {
        /// The supervisor committed it.
        case done
        /// The person declined on the consent card; nothing changed.
        case declined
        /// The App Store has no app with that id.
        case unknownApp
        /// The owner refused: its error code and message.
        case refused(code: String, message: String)
    }

    public var kind: Kind
    /// The app id (`<publisher>/<name>`).
    public var app: String
    /// For an install: `self-hosted:<host>` or `cloud-vm:<machine>`; nil installs without deploying.
    public var deploy: String?
    /// The mutation's idempotency key (one per request; a retry of the same request reuses it).
    public var idempotencyKey: String

    /// Creates a change.
    /// - Parameters:
    ///   - kind: Install or remove.
    ///   - app: The app id.
    ///   - deploy: The deploy target for an install; blank counts as none. Ignored for a removal.
    ///   - idempotencyKey: The request's key; a fresh one by default.
    public init(kind: Kind, app: String, deploy: String? = nil, idempotencyKey: String = "apps-store-change.\(UUID().uuidString)") {
        self.kind = kind
        self.app = app.trimmingCharacters(in: .whitespaces)
        let target = deploy?.trimmingCharacters(in: .whitespaces) ?? ""
        self.deploy = kind == .install && !target.isEmpty ? target : nil
        self.idempotencyKey = idempotencyKey
    }

    /// The supervisor op.
    public var op: String { kind == .install ? "cmux.apps.install" : "cmux.apps.uninstall" }

    /// The op's params (the consent card reads `deploy.target` to name the machine).
    public var params: JSONValue {
        var params: [String: JSONValue] = ["app": .string(app), "idempotency_key": .string(idempotencyKey)]
        if kind == .install { params["grant_optional"] = .bool(false) }
        if let deploy { params["deploy"] = .object(["target": .string(deploy)]) }
        return .object(params)
    }

    /// Sends the change through `provider` (the App Store's confirming provider): the card shows,
    /// and the owner's answer becomes the outcome.
    /// - Parameter provider: The App Store's `cmux.apps.*` provider.
    /// - Returns: How the change ended.
    @MainActor
    public func send(through provider: any PageProvider) async -> Outcome {
        do {
            _ = try await provider.call(op, params: params, context: PageCallContext(page: PageDescriptor.apps.id))
            return .done
        } catch let error as PageError where error == .cancelled {
            return .declined
        } catch let error as PageError where error.code == "apps.unknown" || error.details?["code"]?.stringValue == "apps.unknown" {
            return .unknownApp
        } catch let error as PageError {
            return .refused(code: error.details?["code"]?.stringValue ?? error.code, message: error.message)
        } catch {
            return .refused(code: "error", message: String(describing: error))
        }
    }
}
