import AppKit
import CmuxSwiftRender
import Testing
@testable import CmuxSwiftRenderUI

@MainActor
@Suite("RenderNode → NSMenu builder")
struct RenderNodeMenuBuilderTests {
    private func capturingDispatch(_ box: MenuActionCapture) -> SidebarActionDispatch {
        SidebarActionDispatch { action in box.actions.append(action) }
    }

    private func fire(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        _ = item.target?.perform(action, with: item)
    }

    @Test("buttons become titled, enabled items that dispatch their action")
    func buttonsDispatch() {
        let box = MenuActionCapture()
        let focus = ButtonAction(commands: [.cmux(method: "workspace.focus", params: ["id": "w1"])])
        let pin = ButtonAction(commands: [.cmux(method: "workspace.togglePin", params: ["id": "w1"])])
        let nodes = [
            RenderNode(kind: .button, text: "Focus", action: focus),
            RenderNode(kind: .divider),
            RenderNode(kind: .button, text: "Pin", action: pin),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: capturingDispatch(box)).makeMenu(nodes: nodes)

        #expect(menu.items.count == 3)
        #expect(menu.items[0].title == "Focus")
        #expect(menu.items[0].isEnabled)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "Pin")

        fire(menu.items[0])
        fire(menu.items[2])
        #expect(box.actions == [focus, pin])
    }

    @Test("nested Menu becomes a submenu whose items dispatch")
    func nestedMenu() throws {
        let box = MenuActionCapture()
        let red = ButtonAction(commands: [.cmux(method: "workspace.color", params: ["color": "red"])])
        let nodes = [
            RenderNode(kind: .menu, text: "Color", children: [
                RenderNode(kind: .button, text: "Red", action: red),
                RenderNode(kind: .button, text: "Blue",
                           action: ButtonAction(commands: [.cmux(method: "workspace.color", params: ["color": "blue"])])),
            ]),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: capturingDispatch(box)).makeMenu(nodes: nodes)

        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == "Color")
        let submenu = try #require(menu.items[0].submenu)
        #expect(submenu.items.map(\.title) == ["Red", "Blue"])

        fire(submenu.items[0])
        #expect(box.actions == [red])
    }

    @Test("submenu parents without presentable descendants are omitted")
    func emptySubmenusOmitted() {
        let nodes = [
            RenderNode(kind: .menu, text: "Empty", children: [
                RenderNode(kind: .divider),
                RenderNode(kind: .spacer),
            ]),
            RenderNode(kind: .menu, text: "Nested Empty", children: [
                RenderNode(kind: .menu, text: "Child Empty", children: [
                    RenderNode(kind: .divider),
                    RenderNode(kind: .spacer),
                ]),
            ]),
            RenderNode(kind: .button, text: "Keep", action: ButtonAction(commands: [.log("keep")])),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: .noop).makeMenu(nodes: nodes)

        #expect(menu.items.map(\.title) == ["Keep"])
    }

    @Test("explicit .disabled(true) disables the item; false keeps it live")
    func disabledModifier() {
        let action = ButtonAction(commands: [.log("x")])
        let nodes = [
            RenderNode(kind: .button, text: "Off",
                       modifiers: [RenderModifier(name: "disabled", args: [ModifierArg(label: nil, value: "true")])],
                       action: action),
            RenderNode(kind: .button, text: "On",
                       modifiers: [RenderModifier(name: "disabled", args: [ModifierArg(label: nil, value: "false")])],
                       action: action),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: .noop).makeMenu(nodes: nodes)

        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[0].action == nil)
        #expect(menu.items[1].isEnabled)
        #expect(menu.items[1].action != nil)
    }

    @Test("a container's .disabled(true) propagates to descendants, matching SwiftUI")
    func containerDisabledPropagates() throws {
        let action = ButtonAction(commands: [.log("x")])
        let nodes = [
            RenderNode(kind: .group,
                       children: [
                           RenderNode(kind: .button, text: "Delete", action: action),
                           // `.disabled(false)` cannot re-enable inside a
                           // disabled ancestor, same as SwiftUI's environment.
                           RenderNode(kind: .button, text: "Rename",
                                      modifiers: [RenderModifier(name: "disabled", args: [ModifierArg(label: nil, value: "false")])],
                                      action: action),
                           RenderNode(kind: .menu, text: "Color", children: [
                               RenderNode(kind: .button, text: "Red", action: action),
                           ]),
                       ],
                       modifiers: [RenderModifier(name: "disabled", args: [ModifierArg(label: nil, value: "true")])]),
            RenderNode(kind: .button, text: "Outside", action: action),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: .noop).makeMenu(nodes: nodes)

        #expect(menu.items.map(\.title) == ["Delete", "Rename", "Color", "Outside"])
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[0].action == nil)
        #expect(!menu.items[1].isEnabled)
        #expect(!menu.items[2].isEnabled)
        let submenu = try #require(menu.items[2].submenu)
        #expect(!submenu.items[0].isEnabled)
        #expect(menu.items[3].isEnabled)
    }

    @Test("rich-label button derives its title and icon from the label subtree")
    func richLabelButton() {
        let box = MenuActionCapture()
        let open = ButtonAction(commands: [.openURL("https://example.com/pr/1")])
        let nodes = [
            RenderNode(kind: .button, children: [
                RenderNode(kind: .hstack, children: [
                    RenderNode(kind: .image, systemName: "arrow.up.forward"),
                    RenderNode(kind: .text, text: "Open PR"),
                ]),
            ], action: open),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: capturingDispatch(box)).makeMenu(nodes: nodes)

        #expect(menu.items[0].title == "Open PR")
        #expect(menu.items[0].image != nil)
        fire(menu.items[0])
        #expect(box.actions == [open])
    }

    @Test("plain Text and Label rows are visible but inert")
    func textRowsInert() {
        let nodes = [
            RenderNode(kind: .text, text: "3 agents running"),
            RenderNode(kind: .label, text: "Status", systemName: "bolt"),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: .noop).makeMenu(nodes: nodes)

        #expect(menu.items.map(\.title) == ["3 agents running", "Status"])
        #expect(menu.items.allSatisfy { !$0.isEnabled && $0.action == nil })
        #expect(menu.items[1].image != nil)
    }

    @Test("containers flatten and Section headers render as inert rows")
    func containersFlatten() {
        let nodes = [
            RenderNode(kind: .group, children: [
                RenderNode(kind: .button, text: "A", action: ButtonAction(commands: [.log("a")])),
            ]),
            RenderNode(kind: .section, text: "More", children: [
                RenderNode(kind: .button, text: "B", action: ButtonAction(commands: [.log("b")])),
            ]),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: .noop).makeMenu(nodes: nodes)

        #expect(menu.items.map(\.title) == ["A", "More", "B"])
        #expect(!menu.items[1].isEnabled)
        #expect(menu.items[0].isEnabled)
        #expect(menu.items[2].isEnabled)
    }

    @Test("container onTapGesture actions become menu items while descendants remain")
    func containerActionsPreserved() throws {
        let box = MenuActionCapture()
        let stackAction = ButtonAction(commands: [.log("stack")])
        let sectionAction = ButtonAction(commands: [.log("section")])
        let menuAction = ButtonAction(commands: [.log("menu")])
        let nodes = [
            RenderNode(kind: .vstack, text: "Stack", children: [
                RenderNode(kind: .button, text: "Stack child", action: ButtonAction(commands: [.log("stack-child")])),
            ], action: stackAction),
            RenderNode(kind: .section, text: "Section", children: [
                RenderNode(kind: .button, text: "Section child", action: ButtonAction(commands: [.log("section-child")])),
            ], action: sectionAction),
            RenderNode(kind: .menu, text: "Menu", children: [
                RenderNode(kind: .button, text: "Menu child", action: ButtonAction(commands: [.log("menu-child")])),
            ], action: menuAction),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: capturingDispatch(box)).makeMenu(nodes: nodes)

        #expect(menu.items.map(\.title) == ["Stack", "Stack child", "Section", "Section child", "Menu", "Menu"])
        #expect(menu.items[0].isEnabled)
        #expect(menu.items[2].isEnabled)
        #expect(menu.items[4].isEnabled)
        let submenu = try #require(menu.items[5].submenu)
        #expect(submenu.items.map(\.title) == ["Menu child"])

        fire(menu.items[0])
        fire(menu.items[2])
        fire(menu.items[4])
        #expect(box.actions == [stackAction, sectionAction, menuAction])
    }

    @Test("non-representable kinds fall back to text-only rows or are skipped")
    func nonRepresentableFallback() {
        let nodes = [
            RenderNode(kind: .rectangle),
            RenderNode(kind: .spacer),
            RenderNode(kind: .vstack, children: [
                RenderNode(kind: .circle),
                RenderNode(kind: .text, text: "kept"),
            ]),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: .noop).makeMenu(nodes: nodes)

        #expect(menu.items.map(\.title) == ["kept"])
    }

    @Test("keyboardShortcut maps to the item's key-equivalent hint")
    func keyboardShortcutHint() {
        let nodes = [
            RenderNode(kind: .button, text: "Select",
                       modifiers: [RenderModifier(name: "keyboardShortcut",
                                                  args: [ModifierArg(label: nil, value: ".return")])],
                       action: ButtonAction(commands: [.log("select")])),
            RenderNode(kind: .button, text: "Copy",
                       modifiers: [RenderModifier(name: "keyboardShortcut",
                                                  args: [
                                                      ModifierArg(label: nil, value: "\"c\""),
                                                      ModifierArg(label: "modifiers", value: "[.command, .shift]"),
                                                  ])],
                       action: ButtonAction(commands: [.log("copy")])),
            RenderNode(kind: .button, text: "Period",
                       modifiers: [RenderModifier(name: "keyboardShortcut",
                                                  args: [ModifierArg(label: nil, value: "\".\"")])],
                       action: ButtonAction(commands: [.log("period")])),
            RenderNode(kind: .button, text: "Delete",
                       modifiers: [RenderModifier(name: "keyboardShortcut",
                                                  args: [ModifierArg(label: nil, value: ".delete")])],
                       action: ButtonAction(commands: [.log("delete")])),
        ]

        let menu = RenderNodeContextMenuBuilder(dispatch: .noop).makeMenu(nodes: nodes)

        #expect(menu.items[0].keyEquivalent == "\r")
        #expect(menu.items[0].keyEquivalentModifierMask.isEmpty)
        #expect(menu.items[1].keyEquivalent == "c")
        #expect(menu.items[1].keyEquivalentModifierMask == [.command, .shift])
        #expect(menu.items[2].keyEquivalent == ".")
        #expect(menu.items[3].keyEquivalent == String(UnicodeScalar(NSDeleteCharacter)!))
    }

    @Test("overlay presents only when the IR yields actual items")
    func overlayPresentationGate() throws {
        let view = RenderNodeContextMenuView()
        view.dispatch = .noop

        view.nodes = []
        #expect(view.menuForPresentation() == nil)

        view.nodes = [RenderNode(kind: .divider), RenderNode(kind: .spacer)]
        #expect(view.menuForPresentation() == nil)

        view.nodes = [RenderNode(kind: .button, text: "Focus",
                                 action: ButtonAction(commands: [.log("focus")]))]
        let menu = try #require(view.menuForPresentation())
        #expect(menu.items.map(\.title) == ["Focus"])

        // A disabled row (SwiftUI `isEnabled` environment false) offers no
        // menu on any path, mouse or accessibility.
        view.isMenuEnabled = false
        #expect(view.menuForPresentation() == nil)
    }

    @Test("offset overlay hit-tests in its superview coordinate space")
    func offsetOverlayHitTestUsesSuperviewCoordinates() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let overlay = RenderNodeContextMenuView(
            frame: NSRect(x: 100, y: 20, width: 80, height: 40)
        )
        // A non-zero bounds origin ensures hit testing converts from the
        // superview's space instead of relying on equal frame and bounds.
        overlay.bounds = NSRect(x: 10, y: 5, width: 80, height: 40)
        overlay.nodes = [
            RenderNode(kind: .button, text: "Row",
                       action: ButtonAction(commands: [.log("row")]))
        ]
        container.addSubview(overlay)

        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 120, y: 40),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        #expect(overlay.acceptsFirstMouse(for: event))

        // `hitTest` receives points in the superview's coordinates, so the
        // offset overlay must claim the point inside its frame.
        #expect(overlay.performHitTest(
            at: NSPoint(x: 120, y: 40),
            currentEvent: event
        ) === overlay)
        #expect(overlay.performHitTest(
            at: NSPoint(x: 20, y: 20),
            currentEvent: event
        ) == nil)
    }

    @Test("accessibility handle presents through the mounted view and drops it weakly")
    func accessibilityHandleWiring() {
        let handle = RenderNodeContextMenuHandle()
        // No mounted view: presenting is a safe no-op.
        handle.presentMenu()
        #expect(handle.view == nil)

        var view: RenderNodeContextMenuView? = RenderNodeContextMenuView()
        handle.view = view
        #expect(handle.view === view)

        // The handle must not extend the platform view's lifetime.
        view = nil
        #expect(handle.view == nil)
    }

    @Test("a row overlay defers to a nested contextMenu overlay under the pointer")
    func nestedOverlayDeferral() {
        let menuNodes = [RenderNode(kind: .button, text: "Row",
                                    action: ButtonAction(commands: [.log("row")]))]

        // Shape mirrors SwiftUI's overlay hosting: one container holding the
        // row content (which nests its own overlay) and the row's overlay.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let content = NSView(frame: container.bounds)
        let nested = RenderNodeContextMenuView(frame: NSRect(x: 150, y: 0, width: 50, height: 40))
        nested.nodes = menuNodes
        nested.contextMenuPath = [0, 1]
        content.addSubview(nested)
        container.addSubview(content)
        let rowOverlay = RenderNodeContextMenuView(frame: container.bounds)
        rowOverlay.nodes = menuNodes
        rowOverlay.contextMenuPath = [0]
        container.addSubview(rowOverlay)

        // Over the nested overlay: the row overlay must yield.
        #expect(rowOverlay.deeperOverlayClaims(NSPoint(x: 175, y: 20)))
        // Elsewhere in the row: the row overlay handles the click itself.
        #expect(!rowOverlay.deeperOverlayClaims(NSPoint(x: 20, y: 20)))
        // A nested overlay with no menu content never claims.
        nested.nodes = []
        #expect(!rowOverlay.deeperOverlayClaims(NSPoint(x: 175, y: 20)))
        // Non-empty IR that builds no usable menu must not hide the parent.
        nested.nodes = [RenderNode(kind: .divider), RenderNode(kind: .spacer)]
        #expect(!rowOverlay.deeperOverlayClaims(NSPoint(x: 175, y: 20)))
        // A hidden nested overlay never claims.
        nested.nodes = menuNodes
        nested.isHidden = true
        #expect(!rowOverlay.deeperOverlayClaims(NSPoint(x: 175, y: 20)))
    }

    @Test("RenderNodeView traversal gives stacked context menus strict paths")
    func stackedContextMenuPaths() {
        let node = RenderNode(kind: .text, text: "row", modifiers: [
            RenderModifier(name: "contextMenu", children: [
                RenderNode(kind: .button, text: "Outer", action: ButtonAction(commands: [.log("outer")])),
            ]),
            RenderModifier(name: "contextMenu", children: [
                RenderNode(kind: .button, text: "Inner", action: ButtonAction(commands: [.log("inner")])),
            ]),
        ])
        let view = RenderNodeView(node: node, contextMenuPath: [3, 2])
        let plan = view.contextMenuPathPlan(for: node.modifiers)

        // `applyModifiers` wraps each new modifier around the accumulated
        // view, so the second context menu is the outer owner and the first
        // one is its descendant.
        #expect(plan.modifierPaths == [[3, 2, -2, 1], [3, 2]])
        #expect(plan.descendantPath == [3, 2, -2, 1, -2, 0])
        #expect(plan.modifierPaths[0].count > plan.modifierPaths[1].count)
        #expect(plan.modifierPaths[0].starts(with: plan.modifierPaths[1]))
    }

    @Test("nested overlay ownership preserves the shared superview point")
    func nestedOverlayUsesSuperviewPointAcrossOffsets() {
        let menuNodes = [RenderNode(kind: .button, text: "Nested",
                                    action: ButtonAction(commands: [.log("nested")]))]

        // Both overlays are offset from the common container. The point is in
        // the nested overlay's frame only after converting through `content`.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        let content = NSView(frame: NSRect(x: 20, y: 15, width: 260, height: 100))
        let nested = RenderNodeContextMenuView(
            frame: NSRect(x: 110, y: 25, width: 60, height: 40)
        )
        nested.nodes = menuNodes
        nested.contextMenuPath = [0, -2, 1]
        content.addSubview(nested)
        container.addSubview(content)

        let rowOverlay = RenderNodeContextMenuView(
            frame: NSRect(x: 20, y: 15, width: 260, height: 100)
        )
        rowOverlay.nodes = menuNodes
        rowOverlay.contextMenuPath = [0]
        container.addSubview(rowOverlay)

        // Container-space point (145, 50) maps to nested-local (15, 10).
        #expect(rowOverlay.deeperOverlayClaims(NSPoint(x: 145, y: 50)))
        #expect(!rowOverlay.deeperOverlayClaims(NSPoint(x: 90, y: 50)))
    }

    @Test("a sibling row overlay does not suppress the current row menu")
    func siblingOverlayDoesNotClaim() {
        let menuNodes = [RenderNode(kind: .button, text: "Row",
                                    action: ButtonAction(commands: [.log("row")]))]

        // SwiftUI may flatten separate row overlays into one hosting view.
        // The sibling row overlaps this point but is not nested in the row
        // whose overlay is asking whether to defer.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let siblingRow = NSView(frame: NSRect(x: 150, y: 40, width: 50, height: 40))
        let siblingOverlay = RenderNodeContextMenuView(frame: siblingRow.bounds)
        siblingOverlay.nodes = menuNodes
        siblingOverlay.contextMenuPath = [1]
        siblingRow.addSubview(siblingOverlay)
        container.addSubview(siblingRow)

        let rowOverlay = RenderNodeContextMenuView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        rowOverlay.nodes = menuNodes
        rowOverlay.contextMenuPath = [0]
        container.addSubview(rowOverlay)

        // The point is inside both rows. Only a nested overlay in the current
        // row should make `deeperOverlayClaims` return true.
        #expect(!rowOverlay.deeperOverlayClaims(NSPoint(x: 175, y: 60)))
    }

    @Test("interpreter .contextMenu IR round-trips into the expected NSMenu")
    func interpreterEndToEnd() throws {
        let interp = SwiftViewInterpreter()
        let node = interp.evaluate("""
        Text("row").contextMenu {
            Button("Focus") { cmux("workspace.focus", param: "w1") }
            Divider()
            Menu("Color") {
                Button("Red") { cmux("workspace.color", color: "red") }
            }
        }
        """)
        let children = try #require(node?.modifiers.first { $0.name == "contextMenu" }?.children)

        let box = MenuActionCapture()
        let menu = RenderNodeContextMenuBuilder(dispatch: capturingDispatch(box)).makeMenu(nodes: children)

        #expect(menu.items.count == 3)
        #expect(menu.items[0].title == "Focus")
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].submenu?.items.map(\.title) == ["Red"])

        fire(menu.items[0])
        #expect(box.actions == [ButtonAction(commands: [.cmux(method: "workspace.focus", params: ["param": "w1"])])])
    }
}
