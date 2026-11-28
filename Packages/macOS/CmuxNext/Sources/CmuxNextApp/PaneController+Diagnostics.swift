import AppKit
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import CmuxNextTerminal

/// One pane's surface state for `debug.surfaces` and the blank-pane invariant.
struct PaneSurfaceStatus {
    var paneKey: String
    var isVisible: Bool
    /// `visible`, `keep_alive` or `hidden`.
    var presence: String
    var selectedTab: String?
    var shownTab: String?
    var kind: String
    var contentInstalled: Bool
    var contentInWindow: Bool
    var contentSize: CGSize
    var terminal: TerminalSurfaceDiagnostics?
    /// Hover in the pane's tab strip (trailing buttons, tab x).
    var strip: TabStripHoverState?
    /// For a page: whether it draws over the pane (nil for terminals).
    var page: BrowserContentVisibility?
    /// Visible page windows over the pane that are not the shown tab's own
    /// page (another tab's page left on screen).
    var foreignPages: Int = 0
    /// The pane's window is not on screen (`occlusionState` lacks `.visible`).
    var windowOccluded = false
    /// Content in the pane's window may draw now (``WindowDrawPolicy``): it is
    /// on screen, or `render.drawWhenOccluded` is on.
    var windowDrawable = true
    /// For Home's docked tab (`home-dock`): whether its dock view is drawn in this pane's window
    /// (in the window, not hidden, with room). Nil for every other tab. The dock view is the
    /// content that shows, so Home is judged by it, not by a terminal surface or a page window it
    /// does not have (a false `blank pane` fault on every Home, air-blue 2026-11-16).
    var homeDockShown: Bool?

    /// The layout gave the pane no room below its tab strip (a split tree
    /// deeper than the window allows). A layout sizing problem, not a
    /// surface lifecycle one, so it is reported apart from `isBlank`.
    var isCollapsed: Bool {
        isVisible && contentInstalled && contentInWindow && (contentSize.width < 1 || contentSize.height < 1)
    }

    /// A visible pane with a selected tab whose content is missing, detached,
    /// paused or has no grid. A pane whose window may not draw (occluded,
    /// ``WindowDrawPolicy``) shows nothing by design and is never blank; the
    /// invariant checks it again when the window is visible.
    var isBlank: Bool { blankReason != nil }

    /// Why ``isBlank`` holds (`not_shown`, `not_installed`, `not_in_window`, `terminal_not_drawing`,
    /// `page_hidden`, `foreign_page`, `home_dock_not_shown`), nil when the pane is not blank. The
    /// fault and `debug.surfaces` name it, so a blank pane says which check it failed.
    var blankReason: String? {
        guard isVisible, windowDrawable, selectedTab != nil, !isCollapsed else { return nil }
        if selectedTab != shownTab { return "not_shown" }
        // Home's dock is judged by its own view, which is what the pane shows.
        if let homeDockShown { return homeDockShown ? nil : "home_dock_not_shown" }
        if !contentInstalled { return "not_installed" }
        if !contentInWindow { return "not_in_window" }
        if let terminal { return terminal.isPresentable ? nil : "terminal_not_drawing" }
        if let page, !page.isVisible { return "page_hidden" }
        return foreignPages > 0 ? "foreign_page" : nil
    }

    /// An off-screen pane in the keep-alive band whose selected tab has no
    /// live, installed content: scrolling to it would show blank frames
    /// while it re-attaches.
    var isColdKeepAlive: Bool {
        guard presence == "keep_alive", selectedTab != nil else { return false }
        guard selectedTab == shownTab, contentInstalled else { return true }
        if let terminal { return !terminal.hasSurface }
        return false
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "pane": .string(paneKey),
            "visible": .bool(isVisible),
            "presence": .string(presence),
            "cold_keep_alive": .bool(isColdKeepAlive),
            "selected_tab": selectedTab.map(JSONValue.string) ?? .null,
            "shown_tab": shownTab.map(JSONValue.string) ?? .null,
            "kind": .string(kind),
            "content_installed": .bool(contentInstalled),
            "content_in_window": .bool(contentInWindow),
            "content_size": .string("\(Int(contentSize.width))x\(Int(contentSize.height))"),
            "blank": .bool(isBlank),
            "blank_reason": blankReason.map(JSONValue.string) ?? .null,
            "home_dock_shown": homeDockShown.map(JSONValue.bool) ?? .null,
            "collapsed": .bool(isCollapsed),
            "content_visible": .bool(page?.isVisible ?? (terminal?.isPresentable ?? contentInstalled)),
            "foreign_pages": JSONValue(foreignPages),
            "window_occluded": .bool(windowOccluded),
            "window_drawable": .bool(windowDrawable),
        ]
        if let strip {
            object["strip"] = [
                "buttons_revealed": .bool(strip.buttonsRevealed),
                "hovered_tab": strip.hoveredTab.map(JSONValue.string) ?? .null,
                "close_shown": .array(strip.closeShown.map(JSONValue.string)),
            ]
        }
        if let reason = page?.reason { object["content_reason"] = .string(reason) }
        if let terminal {
            object["surface"] = [
                "exists": .bool(terminal.hasSurface),
                "replay_applied": .bool(terminal.hasContent),
                "rendering_suspended": .bool(terminal.renderingSuspended),
                "drawing": terminal.drawing.map(JSONValue.bool) ?? .null,
                "paused": terminal.pause.map { .string($0.rawValue) } ?? .null,
                "grid": terminal.grid.map { .string("\($0.columns)x\($0.rows)") } ?? .null,
                // What the view fits; `grid` follows it once the owner echoes the view's claim.
                "fit_grid": terminal.fitGrid.map { .string("\($0.columns)x\($0.rows)") } ?? .null,
                // What Ghostty's last frame drew: the reflow preview at `fit_grid` while `grid` lags.
                "drawn_grid": terminal.drawnGrid.map { .string("\($0.columns)x\($0.rows)") } ?? .null,
                // Ghostty's frames, cell rebuilds and theme blend frames (a blend frame changes
                // only the color table the shaders read).
                "render_counters": terminal.renderCounters.map { (counters: TerminalRenderCounters) -> JSONValue in
                    .object(counters.byName.mapValues { .number(Double($0)) })
                } ?? .null,
                // Where the terminal is in its window (fractions, top-left origin) for recordings.
                "window_fraction": terminal.windowFraction.map { (rect: CGRect) -> JSONValue in
                    .array([rect.minX, rect.minY, rect.width, rect.height].map { JSONValue.number(Double($0)) })
                } ?? .null,
                "in_host": .bool(terminal.surfaceInHost),
                "in_window": .bool(terminal.inWindow),
                "hidden": .bool(terminal.hidden),
                "view_size": .string("\(Int(terminal.viewSize.width))x\(Int(terminal.viewSize.height))"),
                "layer_size": .string("\(Int(terminal.layerSize.width))x\(Int(terminal.layerSize.height))"),
            ]
        }
        return .object(object)
    }
}

extension PaneController {
    /// The content's kind, as ``surfaceStatus`` and the frame-timing log's `surface` (`WorkspaceContentController`) name it.
    static func kind(of content: TabContent?) -> String {
        switch content?.kind {
        case .chromium, .webkit: "browser"
        case .placeholder: "remote-placeholder"
        case .notice: "agent-elsewhere"
        case let kind?: kind.rawValue
        case nil: "none"
        }
    }

    /// The visibility its own Chromium page reports (a browser tab's; an agent chat's or a page's window), from cheap reads.
    static func pageVisibility(of content: TabContent?) -> BrowserContentVisibility? {
        switch content {
        case .browser(let entry): (entry.tab as? any BrowserContentVisibilityReporting)?.contentVisibility
        case .agent, .page: (content?.childWindowTab as? any BrowserContentVisibilityReporting)?.contentVisibility
        default: nil
        }
    }

    /// Reads the pane's live state without creating any surface.
    var surfaceStatus: PaneSurfaceStatus {
        let content = currentTabKey.flatMap(existingContent(for:))
        let view = content?.view, visibility = Self.pageVisibility(of: content)
        let terminal: TerminalSurfaceDiagnostics? = if case .terminal(let entry) = content { entry.session.diagnostics } else { nil }
        var page: BrowserContentVisibility?
        if case .browser(let entry) = content {
            page = visibility ?? (entry.tab.contentView.window == nil || entry.tab.contentView.isHiddenOrHasHiddenAncestor ? .hidden("not_in_window") : .visible)
        }
        // An agent chat or New Tab page, a cmux page and a browser tab draw in their own Chromium page window: not foreign.
        let ownPages = visibility?.isVisible == true ? 1 : 0
        let installed = view != nil && self.view.content === view && self.view.hostsContent
        return PaneSurfaceStatus(
            paneKey: paneKey,
            isVisible: isVisible,
            presence: presence.name,
            selectedTab: stripModel.selectedID?.rawValue,
            shownTab: currentTabKey,
            kind: Self.kind(of: content),
            contentInstalled: installed,
            contentInWindow: view?.window != nil,
            contentSize: view?.bounds.size ?? .zero,
            terminal: terminal,
            strip: self.view.stripView.hoverState,
            page: page,
            foreignPages: isVisible ? max(0, visiblePageWindowsOverContent - ownPages) : 0,
            windowOccluded: self.view.window.map { !WindowDrawPolicy.isOnScreen($0) } ?? false,
            windowDrawable: WindowDrawPolicy.isDrawable(self.view.window),
            homeDockShown: homeDockShown
        )
    }

    /// Whether the selected tab, when it is Home's docked tab, has its dock view drawn in this
    /// pane's window; nil for any other tab (``PaneSurfaceStatus/homeDockShown``).
    private var homeDockShown: Bool? {
        guard let tab = selectedTab, tab.isHomeDockPage else { return nil }
        guard let provider = services.pages.provider(.homeDock) as? HomeDockTab,
              let dock = provider.view(forTab: tab.id, services: services) else { return false }
        return Self.isDrawn(dock, in: view.window)
    }

    /// `view` is in `window` (or a child window of it), not hidden, and has room.
    static func isDrawn(_ view: NSView, in window: NSWindow?) -> Bool {
        // Its own window, or a child window over it (a page the dock floats over the pane).
        guard let window, let own = view.window, own === window || (own.parent === window && own.isVisible) else { return false }
        return !view.isHiddenOrHasHiddenAncestor
            && view.bounds.width >= 1 && view.bounds.height >= 1
    }
}

extension PaneController {
    /// Visible app windows other than panels, the pane's window and docked
    /// DevTools that cover most of this pane's content area: Chromium page
    /// windows over the pane (child windows or ones Chromium ordered front
    /// on its own).
    var visiblePageWindowsOverContent: Int {
        guard let window = view.window else { return 0 }
        let content = view.convert(view.bounds, to: nil)
        let rect = window.convertToScreen(content)
        let devTools = (currentContent.flatMap { if case .browser(let entry) = $0 { entry.tab } else { nil } }) as? any BrowserDevToolsHosting
        return (NSApp?.windows ?? []).filter { other in
            guard other !== window, other.isVisible, !(other is NSPanel), devTools?.devToolsContains(window: other) != true else { return false }
            let overlap = other.frame.intersection(rect)
            return !overlap.isNull && overlap.width * overlap.height > 0.5 * rect.width * rect.height
        }.count
    }
}
