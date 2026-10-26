import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextFocus
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextOracle
import CmuxNextPalette
import CmuxNextTerminal
import CmuxNextTerminalFind
import CryptoKit
import Foundation
#endif

/// Reads the live combined input state into an `InputObservation`: each
/// window's focus model next to AppKit's first responder and key window,
/// Ghostty's focused surfaces, the layout focus and Chromium page focus.
/// Main actor, read-only, cheap (no layout, no IO).
enum InputObservationBuilder {
    static func observe(_ services: AppServices) -> InputObservation {
        let ghostty = Set(services.cache.focusedTerminalTabs)
        let controllers = services.windows.controllers
        let context = services.registry.context
        return InputObservation(
            windows: controllers.map { window(of: $0, ghostty: ghostty) },
            keyWindow: keyWindow(controllers),
            paletteOpen: context.contains(.paletteOpen),
            activeWindow: services.windows.active?.state.id,
            context: FocusState.Context(terminal: context.contains(.terminalFocused), browser: context.contains(.browserFocused),
                                     agent: context.contains(.agentPaneFocused))
        )
    }

    static func window(of controller: WindowController, ghostty: Set<String>) -> InputObservation.Window {
        let window = controller.window
        var presented: [String: String] = [:]
        var childWindowTabs: [String] = []
        // A cmux page's Chromium tab has its own id; the model knows the page by its tab key.
        var pageTabKeys: [String: String] = [:]
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            guard let key = pane.currentTabKey else { continue }
            presented[pane.paneKey] = key
            if let tab = pane.currentContent?.childWindowTab { childWindowTabs.append(key); pageTabKeys[tab.id.rawValue] = key }
        }
        return InputObservation.Window(
            id: controller.state.id,
            model: controller.focus.state,
            responder: FocusResponderClassifier.classify(window?.firstResponder, in: controller),
            responderClass: window?.firstResponder.map { String(describing: type(of: $0)) },
            isKey: window?.isKeyWindow ?? false,
            layoutFocus: controller.content?.layoutModel.focusedPane?.rawValue,
            ghosttyFocused: presented.values.filter(ghostty.contains).sorted(),
            childPage: controller.focusApplier.focusedChildWindowPageID.map { pageTabKeys[$0] ?? $0 },
            presented: presented,
            childWindowTabs: childWindowTabs.sorted(),
            hasSheet: window?.attachedSheet != nil, topPage: controller.shownTopPage != nil
        )
    }

    static func keyWindow(_ controllers: [WindowController]) -> InputObservation.KeyWindow {
        guard let key = NSApp.keyWindow else { return .none }
        if let controller = controllers.first(where: { $0.window === key }) { return .window(controller.state.id) }
        let kind = String(describing: type(of: key))
        if let parent = key.sheetParent, let controller = controllers.first(where: { $0.window === parent }) {
            return .sheet(window: controller.state.id)
        }
        let owner = key.parent.flatMap { parent in controllers.first { $0.window === parent } }
        if key is NSPanel { return .panel(window: owner?.state.id, kind: kind) }
        if let owner { return .childPage(window: owner.state.id) }
        return .other(kind)
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's `overlays` facet (p15-oracle-038): what sits above each window's content, read from the controllers
/// that own each layer, never from a view tree. The browser's find bar keeps its query in its view (`FindBarView`),
/// so a browser pane reports the find bar closed.
extension InputObservationBuilder {
    static func oracleOverlaysFacet(_ services: AppServices, dialogs: CmuxDialogCenter, toasts: CmuxToastCenter) -> OracleOverlaysFacet {
        OracleOverlaysFacet(hash: oracleSHA256) { [weak services] in
            services.map { oracleOverlays($0, dialogs: dialogs, toasts: toasts) }
        }
    }

    /// Per window in the window manager's order: its shown terminal find bars, visible dialogs, toasts (the
    /// refusal HUD's as `refusalHud`), focus overlays in open order, then the hover card over it; after the
    /// windows, the layers no cmux window owns (an app dialog, the palette or a card over no cmux window).
    static func oracleOverlays(_ services: AppServices, dialogs: CmuxDialogCenter, toasts: CmuxToastCenter) -> OracleOverlaysFacet.Reading {
        typealias Layer = OracleOverlaysFacet.Layer
        var reading = OracleOverlaysFacet.Reading()
        var unplaced = dialogs.records.filter(\.visible).map(\.id)
        let card = services.hoverCards.machine.shownTarget
        var cardPlaced = false
        let palette = services.palette
        for controller in services.windows.controllers {
            let id = ControlWindowInfo.publicID(forKey: controller.state.id)
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                if case .terminal(let entry)? = pane.currentContent, entry.session.find.isPresented { reading.stack.append(Layer(.findBar, window: id)) }
            }
            let window = controller.window
            if let window {
                let shown = unplaced.filter { dialogs.window(of: $0) === window }
                unplaced.removeAll { shown.contains($0) }
                reading.stack += shown.map { _ in Layer(.dialog, window: id) }
                reading.stack += toasts.toasts(in: window).map { Layer($0.id == RefusalHUD.toastID ? .refusalHud : .toast, window: id) }
            }
            reading.stack += controller.focus.state.overlays.map { Layer(oracleKind($0), window: id) }
            if let card, let window, card.window == window.windowNumber {
                cardPlaced = true
                reading.stack.append(Layer(.hoverCard, window: id))
            }
        }
        reading.stack += unplaced.map { _ in Layer(.dialog, window: nil) }
        if palette.isVisible, !reading.stack.contains(where: { $0.kind == .palette }) { reading.stack.append(Layer(.palette, window: nil)) }
        if card != nil, !cardPlaced { reading.stack.append(Layer(.hoverCard, window: nil)) }
        if palette.isVisible {
            let rows = palette.model.rows
            reading.palette = .init(open: true, mode: palette.model.currentPageID, query: palette.model.query,
                                    rowIDs: rows.prefix(OracleOverlaysFacet.topCount).map(\.id),
                                    selectedIndex: palette.model.selectedRowID.flatMap { selected in rows.firstIndex { $0.id == selected } })
        }
        reading.dialogSpecID = dialogs.records.last(where: \.visible)?.spec.identifier
        reading.hoverCardTarget = card.flatMap { target in
            OracleOverlaysFacet.itemID(ofHoverTarget: target.id.rawValue) { services.workspace(id: $0)?.resourceID?.rawValue ?? $0 }
        }
        if let pane = services.windows.active?.focusedPane, case .terminal(let entry)? = pane.currentContent {
            let find = entry.session.find
            reading.findBar = .init(open: find.isPresented, pane: pane.pane.id, query: find.query, matches: find.total ?? 0, selected: find.selected)
        }
        return reading
    }

    static func oracleKind(_ overlay: FocusState.Overlay) -> OracleOverlaysFacet.Kind {
        switch overlay {
        case .palette: .palette
        case .sheet: .sheet
        // The group editor bubble and the rename prompt are panels on a control of the window.
        case .groupEditor, .rename: .popover
        }
    }

    nonisolated static func oracleSHA256(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
