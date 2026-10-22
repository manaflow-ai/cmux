public import CmuxNextActions
import CmuxNextSettings
import Observation

/// Connects the action registry to the control socket: publishes a catalog
/// snapshot to the router whenever descriptors, bindings, or shortcut
/// overrides change, the actions' unavailable reasons alone when the app
/// state they read changes (both on a later frame, coalesced: never in the
/// turn of the split or new tab that changed it), and just the context bits
/// on focus changes; runs `action.run` requests through
/// `ActionRegistry.perform` on the main actor (which re-reads a reason live).
@MainActor
public final class RegistryControlBridge: ControlActionExecutor {
    public let registry: ActionRegistry
    private var router: ControlRouter?
    /// The current observation chain (state-audit R1): each attach starts a
    /// new epoch and detach ends it. A chain armed under an older epoch fires
    /// once more at most and then stops, so detach then attach never leaves
    /// two chains republishing every change.
    private var epoch = 0
    private var isObserving = false

    /// The frames a catalog change republishes on: never in the turn that changed the state (a split, a
    /// new tab), at most once per frame however many changes it saw.
    private let frames: any ControlFrameSource
    /// Action entries built (``info(for:in:categoryTitles:)`` calls): a reason-only change builds none.
    private(set) var entryBuilds = 0
    /// What the next frame's publish must read again: every entry (the registry changed) or only the
    /// unavailable reasons (app state an action's reason reads changed).
    private var entriesStale = false
    private var reasonsStale = false
    private var isScheduled = false
    /// Whether each observation chain is armed; a chain re-arms when its publish reads it again.
    private var entriesArmed = false
    private var reasonsArmed = false

    public init(registry: ActionRegistry, frames: any ControlFrameSource = MainQueueFrameSource()) {
        self.registry = registry
        self.frames = frames
    }

    /// Publishes the current catalog to `router` and keeps it current.
    public func attach(to router: ControlRouter) {
        self.router = router
        router.updateCatalog(Self.catalog(from: registry))
        entryBuilds += registry.entries.count
        guard !isObserving else { return }
        isObserving = true
        epoch += 1
        (entriesArmed, reasonsArmed, entriesStale, reasonsStale, isScheduled) = (false, false, false, false, false)
        observeEntries(epoch: epoch)
        observeReasons(epoch: epoch)
        observeContext(epoch: epoch)
    }

    public func detach() {
        router = nil
        isObserving = false
        epoch += 1
    }

    /// The registry's own state: a change rebuilds every entry.
    private func observeEntries(epoch: Int) {
        guard isObserving, epoch == self.epoch, !entriesArmed else { return }
        entriesArmed = true
        withObservationTracking {
            _ = registry.descriptors
            _ = registry.actions
            _ = registry.shortcutOverrides
            _ = registry.chordOverrides
            _ = registry.disabledFeatures
        } onChange: { [weak self] in
            // onChange runs inside the mutation, before the value is stored.
            // task-owner: marks the catalog stale; ends when its epoch is not current (state-audit R1)
            Task { @MainActor in self?.stale(entries: true, epoch: epoch) }
        }
    }

    /// The app state the unavailable reasons read (the daemon store, focus, capabilities): it moves on every
    /// split and new tab, so a change re-reads the reasons only, on a later frame.
    private func observeReasons(epoch: Int) {
        guard isObserving, epoch == self.epoch, !reasonsArmed else { return }
        reasonsArmed = true
        withObservationTracking {
            for action in registry.actions { _ = action.unavailableReason?() }
        } onChange: { [weak self] in
            // task-owner: marks the reasons stale; ends when its epoch is not current (state-audit R1)
            Task { @MainActor in self?.stale(entries: false, epoch: epoch) }
        }
    }

    private func stale(entries: Bool, epoch: Int) {
        guard isObserving, epoch == self.epoch else { return }
        if entries { (entriesStale, entriesArmed) = (true, false) } else { (reasonsStale, reasonsArmed) = (true, false) }
        guard !isScheduled else { return }
        isScheduled = true
        frames.scheduleFrame { [weak self] in self?.publish(epoch: epoch) }
    }

    /// One frame's publish: every entry when the registry changed, else the reasons patched into the
    /// published catalog (its context mask and flags stay as published).
    private func publish(epoch: Int) {
        isScheduled = false
        guard isObserving, epoch == self.epoch, let router else { return }
        if entriesStale {
            router.updateCatalog(Self.catalog(from: registry))
            entryBuilds += registry.entries.count
        } else if reasonsStale {
            var catalog = router.catalog
            catalog.actions = catalog.actions.map { action in
                var action = action
                action.unavailableReason = registry.unavailableReason(for: ActionID(rawValue: action.id))
                return action
            }
            router.updateCatalog(catalog)
        }
        (entriesStale, reasonsStale) = (false, false)
        observeEntries(epoch: epoch)
        observeReasons(epoch: epoch)
    }

    private func observeContext(epoch: Int) {
        guard isObserving, epoch == self.epoch else { return }
        withObservationTracking {
            _ = registry.context
        } onChange: { [weak self] in
            // task-owner: observation re-arm; ends when its epoch is not current (state-audit R1)
            Task { @MainActor in
                guard let self, self.isObserving, epoch == self.epoch else { return }
                self.router?.updateContextMask(self.registry.context.rawValue)
                self.observeContext(epoch: epoch)
            }
        }
    }

    // MARK: - Executor

    /// Same as ``performAction(_:)``.
    public func perform(_ request: ControlActionRequest) -> ControlActionOutcome { performAction(request) }

    /// Runs `request` and collects the daemon work its handler started.
    public func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        var outcome = ControlActionOutcome.disabled
        let captured = registry.capturingRun { outcome = performAction(request) }
        return ControlActionRun(outcome: outcome, work: captured.work, results: captured.results)
    }

    /// Runs `request` through the registry. Main actor only.
    public func performAction(_ request: ControlActionRequest) -> ControlActionOutcome {
        let id = registry.canonicalID(for: ActionID(rawValue: request.actionID))
        guard registry.descriptor(for: id) != nil || registry.isBound(id) else { return .unknownAction }
        guard let action = registry.action(for: id) else { return .notBound }
        // Policy first: a turned-off feature's action does not exist for callers.
        if let feature = registry.disabledFeature(for: id) { return .featureDisabled(feature.rawValue) }
        // Every socket run lands here, and its `origin` is the caller's claim.
        if registry.descriptor(for: id)?.isPersonOnly == true {
            return .refused(ControlStrings.text("control.error.personOnly", "Only a person in cmux can run this action"))
        }
        // Reported before the context check, so a context-gated action that
        // cannot exist yet says why instead of "not available here".
        if let reason = registry.unavailableReason(for: id) { return .refused(reason) }
        var invocation = ActionInvocation(
            target: request.target.flatMap(Self.actionTarget),
            arguments: request.arguments.compactMapValues(Self.actionValue),
            origin: ActionOrigin(rawValue: request.origin) ?? .cli,
            focusRequested: request.focus
        )
        invocation.callerApp = request.callerApp
        invocation.besideCaller = request.besideCaller
        invocation.newColumnBeside = request.newColumnBeside
        invocation.opensInBackground = request.background
        invocation.callerAgentSession = request.callerAgentSession
        invocation.callerTerminal = request.callerTerminal
        guard registry.isAvailable(id, for: invocation) else { return .unavailable }
        guard action.isEnabled() else { return .disabled }
        if registry.needsConfirmation(id, invocation) { return .confirmationRequired }
        var ran = false
        let refusal = registry.capturingTypedRefusal { ran = registry.perform(id, invocation: invocation) }
        if let refusal { return refusal.isNotFound ? .notFound(refusal.reason) : .refused(refusal.reason) }
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
        let surfaces: [String: Any] = ActionSurfaceExport.object(descriptor)
        info.surfaces = ["palette", "cli", "context_menu", "mcp"].reduce(into: [:]) { $0[$1] = surfaces[$1] as? String }
        info.contextMenus = surfaces["context_menus"] as? [String] ?? []
        // Snapshot for `action.list`; `action.run` re-reads it live.
        info.unavailableReason = registry.unavailableReason(for: descriptor.id)
        info.disabledFeature = registry.disabledFeature(for: descriptor.id)?.rawValue
        info.isDestructive = descriptor.isDestructive
        info.startsTerminal = descriptor.startsTerminal
        info.isCLI = descriptor.cli
        info.waitsForResult = descriptor.waitsForResult
        info.waitsForPerson = descriptor.waitsForPerson
        info.waitsForKeyedCreate = descriptor.waitsForKeyedCreate
        info.focuses = descriptor.focuses
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
        (.checkpointCaptureAvailable, "checkpointCaptureAvailable"),
        (.recordingShortcut, "recordingShortcut"),
        (.omnibarFocused, "omnibarFocused"),
        (.codeEditorFocused, "codeEditorFocused"),
        (.diffViewerFocused, "diffViewerFocused"),
        (.filePreviewFocused, "filePreviewFocused"),
        (.markdownFocused, "markdownFocused"),
        (.markdownReadOnlyFocused, "markdownReadOnlyFocused"),
        (.markdownEditorFocused, "markdownEditorFocused"),
        (.rightSidebarFocused, "rightSidebarFocused"),
        (.fileExplorerFocused, "fileExplorerFocused"),
        (.textBoxFocused, "textBoxFocused"),
        (.paletteOpen, "paletteOpen"),
        (.signedIn, "signedIn"),
        (.signedOut, "signedOut"),
        (.cloudWorkspace, "cloudWorkspace"),
        (.homeChannelsEnabled, "homeChannelsEnabled"),
        (.webViewFocused, "webViewFocused"),
    ]
}
