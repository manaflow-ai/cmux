import AppKit
import Combine
import Foundation
import ObjectiveC
import OSLog
import CmuxSidebarScript

/// Loads, compiles, and updates the user's optional sidebar customization script.
///
/// The sidebar renders rows natively unless `~/.config/cmux/sidebar.lisp` exists
/// and compiles. When it does, `script` is non-nil and each row renders through
/// it; any compile or render fault falls back to the native row, so a broken
/// script can never break the sidebar.
@MainActor
final class SidebarScriptStore: ObservableObject {
    static let shared = SidebarScriptStore()

    /// The compiled script, or nil when the user has no `sidebar.lisp` (or it
    /// failed to compile).
    @Published private(set) var script: SidebarScript?

    /// The active source text. Non-nil even for a script that failed to compile
    /// so the menu can still report whether it matches a bundled demo.
    @Published private(set) var source: String?

    /// Bumps whenever the active script identity changes. Folded into the row's
    /// equatability so a new script re-renders every row.
    @Published private(set) var version: Int = 0

    private static let logger = Logger(subsystem: "com.manaflow.cmux", category: "SidebarScript")
    private let url: URL

    /// Logs a per-row render failure. Called from the sidebar row when a script
    /// faults so the row can fall back to native rendering.
    static func logRenderFailure(_ error: Error) {
        logger.error("sidebar.lisp render failed: \(String(describing: error), privacy: .public)")
    }

    /// The default path users edit to customize the sidebar.
    nonisolated static var scriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/sidebar.lisp")
    }

    init(url: URL = SidebarScriptStore.scriptURL) {
        self.url = url
        reload()
    }

    var activeDemoId: String? {
        source.flatMap(SidebarScriptDemo.matchingDemoId(for:))
    }

    var isNativeActive: Bool {
        source == nil
    }

    func reload() {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            setSource(nil, compiledScript: nil)
            return
        }

        load(source: source)
    }

    func useNativeSidebar() {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            setSource(nil, compiledScript: nil)
            Self.logger.info("Disabled custom sidebar.lisp.")
        } catch {
            Self.logger.error("Failed to remove sidebar.lisp: \(String(describing: error), privacy: .public)")
        }
    }

    func applyDemo(_ demo: SidebarScriptDemo) {
        applySource(demo.source, logName: demo.id)
    }

    private func applySource(_ source: String, logName: String) {
        do {
            let compiledScript = try SidebarScript(source: source)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try source.write(to: url, atomically: true, encoding: .utf8)
            setSource(source, compiledScript: compiledScript)
            Self.logger.info("Applied sidebar Lisp demo '\(logName, privacy: .public)' (\(source.count) chars).")
        } catch {
            Self.logger.error("Failed to apply sidebar Lisp demo '\(logName, privacy: .public)': \(String(describing: error), privacy: .public)")
        }
    }

    private func load(source: String) {
        do {
            let compiledScript = try SidebarScript(source: source)
            setSource(source, compiledScript: compiledScript)
            Self.logger.info("Loaded custom sidebar.lisp (\(source.count) chars).")
        } catch {
            setSource(source, compiledScript: nil)
            Self.logger.error("sidebar.lisp failed to compile: \(String(describing: error), privacy: .public)")
        }
    }

    private func setSource(_ source: String?, compiledScript: SidebarScript?) {
        self.source = source
        script = compiledScript
        version = source?.hashValue ?? 0
    }
}

private var sidebarScriptLayoutMenuTargetKey: UInt8 = 0

@MainActor
enum SidebarScriptLayoutMenuController {
    static func showMenu(scriptStore: SidebarScriptStore, anchorView: NSView, event: NSEvent?) {
        let menu = NSMenu(title: String(localized: "sidebar.script.menu.title", defaultValue: "Sidebar Layouts"))
        let target = SidebarScriptLayoutMenuTarget(scriptStore: scriptStore)
        objc_setAssociatedObject(menu, &sidebarScriptLayoutMenuTargetKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let nativeItem = NSMenuItem(
            title: String(localized: "sidebar.script.menu.native", defaultValue: "Native Sidebar"),
            action: #selector(SidebarScriptLayoutMenuTarget.useNativeSidebar(_:)),
            keyEquivalent: ""
        )
        nativeItem.target = target
        nativeItem.state = scriptStore.isNativeActive ? .on : .off
        nativeItem.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        menu.addItem(nativeItem)
        menu.addItem(.separator())

        for demo in SidebarScriptDemo.all {
            let item = NSMenuItem(
                title: demoTitle(demo),
                action: #selector(SidebarScriptLayoutMenuTarget.applyDemo(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = demo.id
            item.state = scriptStore.activeDemoId == demo.id ? .on : .off
            item.image = NSImage(systemSymbolName: iconName(for: demo), accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.popUp(
            positioning: nil,
            at: menuPoint(anchorView: anchorView, event: event),
            in: anchorView
        )
    }

    private static func menuPoint(anchorView: NSView, event: NSEvent?) -> NSPoint {
        guard let event else {
            return NSPoint(x: 0, y: anchorView.bounds.maxY + 2)
        }
        return anchorView.convert(event.locationInWindow, from: nil)
    }

    private static func iconName(for demo: SidebarScriptDemo) -> String {
        switch demo.id {
        case "default": return "text.alignleft"
        case "liquid-glass": return "sparkles"
        case "high-density-ide": return "rectangle.grid.1x2"
        case "terminal-stealth": return "terminal"
        case "pro-studio": return "slider.horizontal.3"
        case "finder": return "folder.fill"
        case "agent-ops": return "chart.bar.xaxis"
        default: return "sidebar.left"
        }
    }

    private static func demoTitle(_ demo: SidebarScriptDemo) -> String {
        switch demo.id {
        case "default":
            return String(localized: "sidebar.script.demo.default", defaultValue: "Default Lisp")
        case "liquid-glass":
            return String(localized: "sidebar.script.demo.liquidGlass", defaultValue: "Liquid Glass")
        case "high-density-ide":
            return String(localized: "sidebar.script.demo.highDensityIDE", defaultValue: "High-Density IDE")
        case "terminal-stealth":
            return String(localized: "sidebar.script.demo.terminalStealth", defaultValue: "Terminal Stealth")
        case "pro-studio":
            return String(localized: "sidebar.script.demo.proStudio", defaultValue: "Pro Studio")
        case "finder":
            return String(localized: "sidebar.script.demo.finder", defaultValue: "Finder")
        case "agent-ops":
            return String(localized: "sidebar.script.demo.agentOps", defaultValue: "Agent Ops")
        default:
            return demo.id
        }
    }
}

@MainActor
private final class SidebarScriptLayoutMenuTarget: NSObject {
    private let scriptStore: SidebarScriptStore

    init(scriptStore: SidebarScriptStore) {
        self.scriptStore = scriptStore
    }

    @objc func useNativeSidebar(_ sender: NSMenuItem) {
        scriptStore.useNativeSidebar()
    }

    @objc func applyDemo(_ sender: NSMenuItem) {
        guard let demoId = sender.representedObject as? String,
              let demo = SidebarScriptDemo.all.first(where: { $0.id == demoId }) else {
            return
        }
        scriptStore.applyDemo(demo)
    }
}
