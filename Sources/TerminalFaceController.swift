import AppKit
import CMUXAgentLaunch
import CmuxSettings
import CmuxSettingsUI
import Observation
import QuartzCore
import SwiftUI

enum TerminalFaceState: Int, Hashable, Sendable {
    case idle = 0
    case thinking
    case working
    case done
    case needsInput
    case error
}

@MainActor
@Observable
final class TerminalFacePresentation {
    private(set) var configuration = TerminalFaceConfiguration.default
    private(set) var state = TerminalFaceState.idle

    func update(configuration: TerminalFaceConfiguration, state: TerminalFaceState) {
        if self.configuration != configuration {
            self.configuration = configuration
        }
        if self.state != state {
            self.state = state
        }
    }
}

@MainActor
final class TerminalFaceController {
    private let store: JSONConfigStore
    private let key: JSONKey<TerminalFaceConfiguration>
    private var globalConfiguration: TerminalFaceConfiguration
    private var states: [UUID: TerminalFaceState] = [:]
    private var settingsTask: Task<Void, Never>?
    private var editorWindows: [NSWindowController] = []
    private var eventsSinceStatePrune = 0

    init(runtime: SettingsRuntime) {
        store = runtime.jsonStore
        key = runtime.catalog.terminal.face
        globalConfiguration = runtime.jsonStore.snapshotValue(for: key)
        settingsTask = Task { [weak self, store, key] in
            for await value in store.values(for: key) {
                guard let self else { return }
                globalConfiguration = value
                refreshAll()
            }
        }
    }

    deinit { settingsTask?.cancel() }

    func configuration(for panel: TerminalPanel) -> TerminalFaceConfiguration {
        if let override = panel.terminalFaceOverride { return override }
        if let override = AppDelegate.shared?.workspaceFor(tabId: panel.workspaceId)?.terminalFaceOverride {
            return override
        }
        return globalConfiguration
    }

    func refresh(panel: TerminalPanel) {
        let configuration = configuration(for: panel)
        let state = configuration.reactsToAgents ? states[panel.id, default: .idle] : .idle
        panel.terminalFacePresentation.update(configuration: configuration, state: state)
    }

    func refresh(workspace: Workspace) {
        workspace.panels.values.compactMap { $0 as? TerminalPanel }.forEach(refresh(panel:))
    }

    func refreshAll() {
        let workspaces = liveWorkspaces
        pruneStates(in: workspaces)
        for workspace in workspaces { refresh(workspace: workspace) }
    }

    func noteHookEvent(_ event: WorkstreamEvent) {
        eventsSinceStatePrune += 1
        if eventsSinceStatePrune >= 64 {
            pruneStates(in: liveWorkspaces)
        }
        let state: TerminalFaceState
        switch event.hookEventName {
        case .userPromptSubmit, .preCompact:
            state = .thinking
        case .postToolUse where toolUseFailed(event):
            state = .error
        case .preToolUse, .postToolUse, .todoWrite, .subagentStart, .subagentStop, .postCompact:
            state = .working
        case .permissionRequest, .askUserQuestion, .exitPlanMode, .notification:
            state = .needsInput
        case .stop:
            state = .done
        case .sessionStart, .sessionEnd:
            state = .idle
        }
        guard let panel = panel(for: event) else { return }
        states[panel.id] = state
        refresh(panel: panel)
    }

    func presentEditor(for panel: TerminalPanel) {
        let inherited = AppDelegate.shared?.workspaceFor(tabId: panel.workspaceId)?.terminalFaceOverride
            ?? globalConfiguration
        presentEditor(
            title: String(localized: "terminalFace.editor.terminalTitle", defaultValue: "Terminal Face"),
            override: panel.terminalFaceOverride,
            inherited: inherited,
            save: { [weak panel] in panel?.setTerminalFaceOverride($0) }
        )
    }

    func toggle(for panel: TerminalPanel) {
        var configuration = configuration(for: panel)
        configuration.enabled.toggle()
        panel.setTerminalFaceOverride(configuration)
    }

    func presentEditor(for workspace: Workspace) {
        presentEditor(
            title: String(localized: "terminalFace.editor.workspaceTitle", defaultValue: "Workspace Terminal Face"),
            override: workspace.terminalFaceOverride,
            inherited: globalConfiguration,
            save: { [weak workspace] in workspace?.setTerminalFaceOverride($0) }
        )
    }

    private func panel(for event: WorkstreamEvent) -> TerminalPanel? {
        guard let surfaceString = event.surfaceId,
              let surfaceID = UUID(uuidString: surfaceString) else { return nil }
        if let workspaceString = event.workspaceId {
            guard let workspaceID = UUID(uuidString: workspaceString),
                  let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceID)
            else { return nil }
            return workspace.terminalPanel(for: surfaceID)
        }
        for workspace in liveWorkspaces {
            if let panel = workspace.terminalPanel(for: surfaceID) { return panel }
        }
        return nil
    }

    private var liveWorkspaces: [Workspace] {
        let managers = AppDelegate.shared?.mainWindowContexts.values.map(\.tabManager) ?? []
        return managers.flatMap(\.tabs)
    }

    private func pruneStates(in workspaces: [Workspace]) {
        let liveIDs = Set(workspaces.flatMap { workspace in
            workspace.panels.values.compactMap { ($0 as? TerminalPanel)?.id }
        })
        states = states.filter { liveIDs.contains($0.key) }
        eventsSinceStatePrune = 0
    }

    private func toolUseFailed(_ event: WorkstreamEvent) -> Bool {
        guard let json = event.extraFieldsJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return false }
        return object["is_error"] as? Bool == true
    }

    private func presentEditor(
        title: String,
        override: TerminalFaceConfiguration?,
        inherited: TerminalFaceConfiguration,
        save: @escaping (TerminalFaceConfiguration?) -> Void
    ) {
        let view = TerminalFaceOverrideEditor(
            title: title,
            initialOverride: override,
            inherited: inherited,
            save: save
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.identifier = NSUserInterfaceItemIdentifier("cmux.terminalFaceEditor")
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 650))
        window.center()
        let controller = NSWindowController(window: window)
        editorWindows.removeAll { $0.window?.isVisible != true }
        editorWindows.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TerminalFaceOverlayHost: View {
    let presentation: TerminalFacePresentation
    let isVisible: Bool

    var body: some View {
        TerminalFaceIsolatedHostingView(
            configuration: presentation.configuration,
            state: presentation.state,
            isVisible: isVisible
        )
    }
}

private struct TerminalFaceIsolatedHostingView: NSViewRepresentable {
    let configuration: TerminalFaceConfiguration
    let state: TerminalFaceState
    let isVisible: Bool

    func makeNSView(context: Context) -> TerminalFaceAppKitView {
        let view = TerminalFaceAppKitView()
        view.update(configuration: configuration, state: state, isVisible: isVisible)
        return view
    }

    func updateNSView(_ view: TerminalFaceAppKitView, context: Context) {
        view.update(configuration: configuration, state: state, isVisible: isVisible)
    }
}

@MainActor
private final class TerminalFaceAppKitView: NSView {
    private var configuration = TerminalFaceConfiguration.default
    private var state = TerminalFaceState.idle
    private var isVisible = false
    private let faceLayer = CAShapeLayer()
    private let eyesLayer = CAShapeLayer()
    private let contentLayer = CALayer()
    private var renderedSize = CGSize.zero

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        contentLayer.masksToBounds = false
        faceLayer.isGeometryFlipped = true
        eyesLayer.isGeometryFlipped = true
        contentLayer.addSublayer(faceLayer)
        contentLayer.addSublayer(eyesLayer)
        layer?.addSublayer(contentLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAnimations()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        faceLayer.frame = bounds
        eyesLayer.frame = bounds
        CATransaction.commit()
        if renderedSize != bounds.size {
            renderedSize = bounds.size
            rebuildPaths()
            refreshAnimations()
        }
    }

    func update(
        configuration: TerminalFaceConfiguration,
        state: TerminalFaceState,
        isVisible: Bool
    ) {
        let appearanceChanged = self.configuration != configuration || self.state != state
        let animationChanged = self.configuration.animation != configuration.animation
            || self.configuration.motion != configuration.motion
            || self.configuration.gaze != configuration.gaze
            || self.configuration.scale != configuration.scale
            || self.configuration.enabled != configuration.enabled
            || self.isVisible != isVisible
        self.configuration = configuration
        self.state = state
        self.isVisible = isVisible
        if appearanceChanged { rebuildPaths() }
        if animationChanged { refreshAnimations() }
    }

    private func rebuildPaths() {
        guard configuration.enabled, bounds.width > 0, bounds.height > 0 else {
            faceLayer.path = nil
            eyesLayer.path = nil
            return
        }

        let unit = min(bounds.width, bounds.height) * 0.32 * configuration.scale
        let center = CGPoint(
            x: bounds.width * configuration.horizontalPosition,
            y: bounds.height * configuration.verticalPosition
        )
        let density = configuration.characterDensity
        let dotSize = max(1.8, unit * (0.018 + density * 0.014))
        let outlineCount = Int(24 + density * 34)
        let featureCount = Int(7 + density * 12)
        let facePath = CGMutablePath()
        let eyesPath = CGMutablePath()

        dotsOnEllipse(
            path: facePath,
            center: center,
            radii: CGSize(width: unit, height: unit * 0.82),
            start: 0,
            end: .pi * 2,
            count: outlineCount,
            size: dotSize
        )

        let leftEye = CGPoint(x: center.x - unit * 0.38, y: center.y - unit * 0.20)
        let rightEye = CGPoint(x: center.x + unit * 0.38, y: center.y - unit * 0.20)
        let mouth = CGPoint(x: center.x, y: center.y + unit * 0.29)

        switch state {
        case .idle:
            eyelid(path: eyesPath, center: leftEye, unit: unit, count: featureCount, size: dotSize)
            eyelid(path: eyesPath, center: rightEye, unit: unit, count: featureCount, size: dotSize)
            smile(path: facePath, center: mouth, unit: unit, count: featureCount + 3, size: dotSize)
        case .thinking:
            eye(path: eyesPath, center: leftEye, unit: unit, count: featureCount, size: dotSize)
            eye(path: eyesPath, center: rightEye, unit: unit, count: featureCount, size: dotSize)
            dot(path: facePath, point: mouth, size: dotSize * 1.2)
        case .working:
            line(path: eyesPath, from: offset(leftEye, -0.15 * unit, 0), to: offset(leftEye, 0.15 * unit, 0), count: featureCount, size: dotSize)
            line(path: eyesPath, from: offset(rightEye, -0.15 * unit, 0), to: offset(rightEye, 0.15 * unit, 0), count: featureCount, size: dotSize)
            line(path: facePath, from: offset(mouth, -0.15 * unit, 0), to: offset(mouth, 0.15 * unit, 0), count: featureCount, size: dotSize)
        case .done:
            eye(path: eyesPath, center: leftEye, unit: unit, count: featureCount, size: dotSize)
            eyelid(path: eyesPath, center: rightEye, unit: unit, count: featureCount, size: dotSize)
            smile(path: facePath, center: mouth, unit: unit, count: featureCount + 4, size: dotSize)
        case .needsInput:
            eye(path: eyesPath, center: leftEye, unit: unit, count: featureCount, size: dotSize)
            eye(path: eyesPath, center: rightEye, unit: unit, count: featureCount, size: dotSize)
            eye(path: facePath, center: mouth, unit: unit * 0.55, count: featureCount, size: dotSize)
        case .error:
            cross(path: eyesPath, center: leftEye, unit: unit, count: featureCount, size: dotSize)
            cross(path: eyesPath, center: rightEye, unit: unit, count: featureCount, size: dotSize)
            dotsOnEllipse(path: facePath, center: offset(mouth, 0, unit * 0.15), radii: CGSize(width: unit * 0.30, height: unit * 0.20), start: .pi * 1.15, end: .pi * 1.85, count: featureCount + 3, size: dotSize)
        }

        let color = stateColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shapeLayer in [faceLayer, eyesLayer] {
            shapeLayer.fillColor = color.withAlphaComponent(configuration.opacity).cgColor
            shapeLayer.shadowColor = color.cgColor
            shapeLayer.shadowOffset = .zero
            shapeLayer.shadowRadius = configuration.glow * 8
            shapeLayer.shadowOpacity = Float(configuration.opacity * configuration.glow * 0.35)
        }
        faceLayer.path = facePath
        eyesLayer.path = eyesPath
        CATransaction.commit()
    }

    private var animates: Bool {
        guard configuration.enabled else { return false }
        return switch configuration.animation {
        case .off: false
        case .whenVisible: isVisible
        case .always: true
        }
    }

    private func refreshAnimations() {
        contentLayer.removeAllAnimations()
        eyesLayer.removeAllAnimations()
        guard animates, window != nil else { return }

        let unit = min(bounds.width, bounds.height) * 0.32 * configuration.scale
        addOscillation(
            to: contentLayer,
            keyPath: "transform.translation.x",
            amplitude: unit * 0.035 * configuration.motion,
            duration: 8.85,
            key: "terminalFace.motion.x"
        )
        addOscillation(
            to: contentLayer,
            keyPath: "transform.translation.y",
            amplitude: unit * 0.025 * configuration.motion,
            duration: 11.86,
            key: "terminalFace.motion.y"
        )
        addOscillation(
            to: eyesLayer,
            keyPath: "transform.translation.x",
            amplitude: unit * 0.055 * configuration.gaze,
            duration: 13.37,
            key: "terminalFace.gaze.x"
        )
        addOscillation(
            to: eyesLayer,
            keyPath: "transform.translation.y",
            amplitude: unit * 0.035 * configuration.gaze,
            duration: 16.11,
            key: "terminalFace.gaze.y"
        )
    }

    private func addOscillation(
        to layer: CALayer,
        keyPath: String,
        amplitude: CGFloat,
        duration: CFTimeInterval,
        key: String
    ) {
        guard amplitude > 0 else { return }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = [-amplitude, 0, amplitude, 0, -amplitude]
        animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .cubic
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: key)
    }

    private var stateColor: NSColor {
        let hex = switch state {
        case .idle: configuration.idleColor
        case .thinking: configuration.thinkingColor
        case .working: configuration.workingColor
        case .done: configuration.doneColor
        case .needsInput: configuration.needsInputColor
        case .error: configuration.errorColor
        }
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private func eye(path: CGMutablePath, center: CGPoint, unit: CGFloat, count: Int, size: CGFloat) {
        dotsOnEllipse(path: path, center: center, radii: CGSize(width: unit * 0.13, height: unit * 0.13), start: 0, end: .pi * 2, count: count, size: size)
    }

    private func eyelid(path: CGMutablePath, center: CGPoint, unit: CGFloat, count: Int, size: CGFloat) {
        dotsOnEllipse(path: path, center: center, radii: CGSize(width: unit * 0.18, height: unit * 0.12), start: .pi * 0.12, end: .pi * 0.88, count: count, size: size)
    }

    private func smile(path: CGMutablePath, center: CGPoint, unit: CGFloat, count: Int, size: CGFloat) {
        dotsOnEllipse(path: path, center: offset(center, 0, -unit * 0.15), radii: CGSize(width: unit * 0.32, height: unit * 0.24), start: .pi * 0.15, end: .pi * 0.85, count: count, size: size)
    }

    private func cross(path: CGMutablePath, center: CGPoint, unit: CGFloat, count: Int, size: CGFloat) {
        let radius = unit * 0.13
        line(path: path, from: offset(center, -radius, -radius), to: offset(center, radius, radius), count: count, size: size)
        line(path: path, from: offset(center, -radius, radius), to: offset(center, radius, -radius), count: count, size: size)
    }

    private func line(path: CGMutablePath, from: CGPoint, to: CGPoint, count: Int, size: CGFloat) {
        guard count > 1 else { return }
        for index in 0..<count {
            let progress = CGFloat(index) / CGFloat(count - 1)
            dot(
                path: path,
                point: CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress),
                size: size
            )
        }
    }

    private func dotsOnEllipse(
        path: CGMutablePath,
        center: CGPoint,
        radii: CGSize,
        start: CGFloat,
        end: CGFloat,
        count: Int,
        size: CGFloat
    ) {
        guard count > 1 else { return }
        for index in 0..<count {
            let progress = CGFloat(index) / CGFloat(count - 1)
            let angle = start + (end - start) * progress
            dot(
                path: path,
                point: CGPoint(x: center.x + cos(angle) * radii.width, y: center.y + sin(angle) * radii.height),
                size: size
            )
        }
    }

    private func dot(path: CGMutablePath, point: CGPoint, size: CGFloat) {
        path.addEllipse(in: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
    }

    private func offset(_ point: CGPoint, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: point.x + x, y: point.y + y)
    }
}

@MainActor
private struct TerminalFaceOverrideEditor: View {
    let title: String
    let inherited: TerminalFaceConfiguration
    let save: (TerminalFaceConfiguration?) -> Void
    @State private var usesOverride: Bool
    @State private var draft: TerminalFaceConfiguration

    init(
        title: String,
        initialOverride: TerminalFaceConfiguration?,
        inherited: TerminalFaceConfiguration,
        save: @escaping (TerminalFaceConfiguration?) -> Void
    ) {
        self.title = title
        self.inherited = inherited
        self.save = save
        _usesOverride = State(initialValue: initialOverride != nil)
        _draft = State(initialValue: initialOverride ?? inherited)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Toggle(
                String(localized: "terminalFace.editor.override", defaultValue: "Override inherited settings"),
                isOn: $usesOverride
            )
            ScrollView {
                TerminalFaceConfigurationEditor(configuration: $draft)
                    .disabled(!usesOverride)
                    .padding(.trailing, 8)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Button(String(localized: "terminalFace.editor.reset", defaultValue: "Reset to inherited")) {
                    usesOverride = false
                    draft = inherited
                    save(nil)
                }
                Spacer()
                Button(String(localized: "terminalFace.editor.save", defaultValue: "Save")) {
                    var value = draft
                    value.sanitize()
                    save(usesOverride ? value : nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 610)
    }
}
