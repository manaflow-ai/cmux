import AppKit
import CmuxSwiftRender
import SwiftUI

/// The surface style a JS sidebar requests via `sidebar(fn, { surface: ... })`.
/// Hosts read it to swap their opaque backdrop for translucent material.
public struct CustomSidebarSurfacePreferenceKey: PreferenceKey {
    public static let defaultValue: String? = nil
    public static func reduce(value: inout String?, nextValue: () -> String?) {
        value = nextValue() ?? value
    }
}

/// Mounts one `.js` custom sidebar: owns its ``SidebarJSRuntime`` and renders
/// its retained scene.
///
/// The program runs once per source revision; afterwards only changed data
/// keys cross into the runtime (per-key value diff), and only the scene nodes
/// whose props actually changed invalidate views. This is the fine-grained
/// lane: no per-tick re-parse, no full-tree swap.
public struct JSSidebarHostView: View {
    private let source: String
    private let dataContext: [String: SwiftValue]
    private let dispatch: SidebarActionDispatch

    @State private var engine = JSSidebarEngine()

    /// Creates the host for one JS sidebar program.
    ///
    /// - Parameters:
    ///   - source: The sidebar program (contents of `<name>.js`).
    ///   - dataContext: Live, read-only values exposed to the program as
    ///     `data.<key>()` signals.
    ///   - dispatch: Runs `cmux(...)`/`openURL(...)` actions on the host.
    public init(source: String, dataContext: [String: SwiftValue], dispatch: SidebarActionDispatch) {
        self.source = source
        self.dataContext = dataContext
        self.dispatch = dispatch
    }

    public var body: some View {
        Group {
            if let message = engine.errorMessage {
                errorView(message)
            } else if let rootId = engine.rootId {
                SceneNodeView(nodeId: rootId)
                    .environment(\.sceneStore, engine.store)
                    .environment(\.sceneEventSink, engine.eventSink)
                    .preference(
                        key: CustomSidebarSurfacePreferenceKey.self,
                        value: engine.store?.node(rootId)?.string("surface")
                    )
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .onChange(of: SyncTrigger(source: source, dataContext: dataContext), initial: true) { _, trigger in
            engine.sync(source: trigger.source, dataContext: trigger.dataContext, dispatch: dispatch)
        }
    }

    private func errorView(_ message: String) -> some View {
        // Surface program errors on stderr for lab/debug runs, where the
        // error view itself can't be seen.
        if ProcessInfo.processInfo.environment["CMUX_SIDEBAR_MARQUEE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("sidebar error: \(message)\n".utf8))
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label(
                String(localized: "sidebar.custom.error", defaultValue: "Sidebar error", bundle: .module),
                systemImage: "exclamationmark.triangle.fill"
            )
            .cmuxFont(.caption, weight: .bold)
            .foregroundStyle(.orange)
            Text(message)
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SyncTrigger: Equatable {
    let source: String
    let dataContext: [String: SwiftValue]
}

/// The state half of ``JSSidebarHostView``: restarts the runtime when the
/// source changes and pushes per-key data diffs otherwise.
@MainActor
@Observable
final class JSSidebarEngine {
    private var runtime: SidebarJSRuntime?
    private var lastSource: String?
    private var lastData: [String: SwiftValue] = [:]

    var errorMessage: String? { runtime?.errorMessage }
    var rootId: String? { runtime?.store.rootId }
    var store: SceneStore? { runtime?.store }

    var eventSink: SceneEventSink {
        SceneEventSink { [weak self] nodeId, event, payload in
            // Any interaction outside an active inline editor ends the edit
            // (blur-commits): clicking a SwiftUI row never moves AppKit first
            // responder off the NSTextField by itself, so resign it here.
            // The field's own submit/cancel/edit events must not re-blur -
            // "edit" fires on every keystroke of a live search field.
            if event != "submit", event != "cancel", event != "edit",
               let window = NSApp.keyWindow,
               window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
            self?.runtime?.dispatchEvent(nodeId: nodeId, event: event, payload: payload)
        }
    }

    func sync(source: String, dataContext: [String: SwiftValue], dispatch: SidebarActionDispatch) {
        if source != lastSource || runtime == nil {
            lastSource = source
            lastData = [:]
            let runtime = SidebarJSRuntime()
            runtime.dispatch = dispatch
            self.runtime = runtime
            runtime.start(source: source)
        } else {
            runtime?.dispatch = dispatch
        }
        guard let runtime, runtime.errorMessage == nil else {
            lastData = dataContext
            return
        }
        for (key, value) in dataContext where lastData[key] != value {
            runtime.updateData(key: key, value: value)
        }
        lastData = dataContext
    }
}
