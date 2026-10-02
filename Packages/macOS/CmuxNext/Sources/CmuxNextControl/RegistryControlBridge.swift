public import CmuxNextActions
import CmuxNextSettings
import Observation

/// Connects the action registry to the control socket: publishes a catalog
/// snapshot to the router whenever descriptors, bindings, or shortcut
/// overrides change (and just the context bits on focus changes), and runs
/// `action.run` requests through `ActionRegistry.perform` on the main actor.
@MainActor
public final class RegistryControlBridge: ControlActionExecutor {
    public let registry: ActionRegistry
    private var router: ControlRouter?
    private var isObserving = false

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// Publishes the current catalog to `router` and keeps it current.
    public func attach(to router: ControlRouter) {
        self.router = router
        router.updateCatalog(Self.catalog(from: registry))
        guard !isObserving else { return }
        isObserving = true
        observeCatalog()
        observeContext()
    }

    public func detach() {
        router = nil
        isObserving = false
    }

    private func observeCatalog() {
        guard isObserving else { return }
        withObservationTracking {
            _ = registry.descriptors
            _ = registry.actions
            _ = registry.shortcutOverrides
            _ = registry.chordOverrides
            // Reasons read observable app state (daemon capabilities), so a
            // change there republishes `unavailable_reason` too.
            for action in registry.actions { _ = action.unavailableReason?() }
        } onChange: { [weak self] in
            // onChange runs before the new value is stored; publish after.
            // task-owner: observation re-arm; ends when isObserving is false (reattach epoch: plans/cmux-next/state-audit.md)
            Task { @MainActor in
                guard let self, self.isObserving else { return }
                self.router?.updateCatalog(Self.catalog(from: self.registry))
                self.observeCatalog()
            }
        }
    }

    private func observeContext() {
        guard isObserving else { return }
        withObservationTracking {
            _ = registry.context
        } onChange: { [weak self] in
            // task-owner: observation re-arm; ends when isObserving is false
            Task { @MainActor in
                guard let self, self.isObserving else { return }
                self.router?.updateContextMask(self.registry.context.rawValue)
                self.observeContext()
            }
        }
    }

    // MARK: - Executor

    /// Same as ``performAction(_:)``.
    public func perform(_ request: ControlActionRequest) -> ControlActionOutcome { performAction(request) }

    /// Runs `request` and collects the daemon work its handler started.
    public func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        var outcome = ControlActionOutcome.disabled
        let work = registry.capturingWork { outcome = performAction(request) }
        return ControlActionRun(outcome: outcome, work: work)
    }

    /// Runs `request` through the registry. Main actor only.
    public func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        let id = registry.canonicalID(for: ActionID(rawValue: request.actionID))
        guard registry.descriptor(for: id) != nil || registry.isBound(id) else { return .unknownAction }
        guard let action = registry.action(for: id) else { return .notBound }
        // Every socket run lands here, and its `origin` is the caller's claim.
        if registry.descriptor(for: id)?.isPersonOnly == true {
            return .refused(ControlStrings.text("control.error.personOnly", "Only a person in cmux can run this action"))
        }
        // Reported before the context check, so a context-gated action that
        // cannot exist yet says why instead of "not available here".
        if let reason = registry.unavailableReason(for: id) { return .refused(reason) }
        let invocation = ActionInvocation(
            target: request.target.flatMap(Self.actionTarget),
            arguments: request.arguments.compactMapValues(Self.actionValue),
            origin: ActionOrigin(rawValue: request.origin) ?? .cli,
            focusRequested: request.focus
        )
        guard registry.isAvailable(id, for: invocation) else { return .unavailable }
        guard action.isEnabled() else { return .disabled }
        if registry.needsConfirmation(id, invocation) { return .confirmationRequired }
        var ran = false
        let refusal = registry.capturingRefusal { ran = registry.perform(id, invocation: invocation) }
        if let refusal { return .refused(refusal) }
        return ran ? .ran : .disabled
    }

    static func actionTarget(_ ref: ControlTargetRef) -> ActionTargetRef? {
        ActionTargetKind(rawValue: ref.kind).map { ActionTargetRef(kind: $0, id: ref.id) }
    }

    static func actionValue(_ value: ControlValue) -> ActionValue? {
        switch value {
        case .string(let text): .string(text)
        case .int(let number): .int(number)
        case .bool(let flag): .bool(flag)
        case .target(let ref): actionTarget(ref).map(ActionValue.target)
        }
    }

    // MARK: - Catalog snapshot

    /// A wire snapshot of every registry entry (catalog descriptors plus
    /// ad hoc bound actions).
    public static func catalog(from registry: ActionRegistry) -> ControlCatalog {
        // Localized once per snapshot, not once per action.
        let categoryTitles = Dictionary(uniqueKeysWithValues: ActionCategory.allCases.map { ($0, $0.title) })
        let actions = registry.entries.map { entry in info(for: entry, in: registry, categoryTitles: categoryTitles) }
        let debugAvailable = DevTools.isEnabled
        return ControlCatalog(
            actions: actions,
            contextMask: registry.context.rawValue,
            aliases: Dictionary(uniqueKeysWithValues: registry.aliases.map { ($0.key.rawValue, $0.value.rawValue) }),
            targetKinds: ActionTargetKind.allCases.map(\.rawValue),
            debugActionsAvailable: debugAvailable
        )
    }

    static func info(for entry: ActionEntry, in registry: ActionRegistry,
                     categoryTitles: [ActionCategory: String] = [:]) -> ControlActionInfo {
        let descriptor = entry.descriptor
        let shortcut = registry.effectiveShortcut(for: descriptor.id)
        var info = ControlActionInfo(
            id: descriptor.id.rawValue,
            title: descriptor.title,
            category: descriptor.category.rawValue,
            categoryTitle: categoryTitles[descriptor.category] ?? descriptor.category.title,
            cliName: descriptor.cliName,
            symbol: descriptor.symbol,
            keywords: descriptor.keywords,
            shortcut: registry.shortcutDisplay(for: descriptor.id),
            shortcutConfig: descriptor.shortcutLabel == nil
                ? shortcut.map { ShortcutBindingFormat.configString(SettingsApplier.stroke(for: $0)) }
                : nil,
            arguments: descriptor.arguments.map(argumentInfo),
            targets: descriptor.targets.map(\.rawValue),
            requiresMask: descriptor.requires.rawValue,
            requires: contextNames.filter { descriptor.requires.contains($0.0) }.map(\.1),
            isBound: entry.isBound,
            isDebugOnly: descriptor.isDebugOnly,
            mainMenu: descriptor.mainMenu?.rawValue
        )
        let surfaces = ActionSurfaceExport.object(descriptor)
        info.surfaces = ["palette", "cli", "context_menu", "mcp"].reduce(into: [:]) { $0[$1] = surfaces[$1] as? String }
        info.contextMenus = surfaces["context_menus"] as? [String] ?? []
        // Snapshot for `action.list`; `action.run` re-reads it live.
        info.unavailableReason = registry.unavailableReason(for: descriptor.id)
        info.isDestructive = descriptor.isDestructive
        info.startsTerminal = descriptor.startsTerminal
        info.waitsForResult = descriptor.waitsForResult
        return info
    }

    static func argumentInfo(_ argument: ActionArgument) -> ControlArgumentInfo {
        switch argument.kind {
        case .string:
            ControlArgumentInfo(name: argument.name, title: argument.title, kind: .string, isRequired: argument.isRequired)
        case .int(let range):
            ControlArgumentInfo(name: argument.name, title: argument.title, kind: .int, isRequired: argument.isRequired, range: range)
        case .bool:
            ControlArgumentInfo(name: argument.name, title: argument.title, kind: .bool, isRequired: argument.isRequired)
        case .enumeration(let cases):
            ControlArgumentInfo(
                name: argument.name, title: argument.title, kind: .enumeration, isRequired: argument.isRequired,
                choices: cases.map { ControlArgumentInfo.Choice(value: $0.value, title: $0.title) }
            )
        case .target(let kind):
            ControlArgumentInfo(name: argument.name, title: argument.title, kind: .target, isRequired: argument.isRequired, targetKind: kind.rawValue)
        }
    }

    /// Display names for `ActionContext` bits (the option set is not
    /// enumerable). Unknown future bits are simply not named.
    static let contextNames: [(ActionContext, String)] = [
        (.terminalFocused, "terminalFocused"),
        (.browserFocused, "browserFocused"),
        (.canvasLayout, "canvasLayout"),
        (.simulatorFocused, "simulatorFocused"),
        (.agentPaneFocused, "agentPaneFocused"),
        (.diffViewerFocused, "diffViewerFocused"),
        (.filePreviewFocused, "filePreviewFocused"),
        (.markdownFocused, "markdownFocused"),
        (.rightSidebarFocused, "rightSidebarFocused"),
        (.fileExplorerFocused, "fileExplorerFocused"),
        (.textBoxFocused, "textBoxFocused"),
        (.paletteOpen, "paletteOpen"),
        (.signedIn, "signedIn"),
        (.signedOut, "signedOut"),
        (.cloudWorkspace, "cloudWorkspace"),
    ]
}
