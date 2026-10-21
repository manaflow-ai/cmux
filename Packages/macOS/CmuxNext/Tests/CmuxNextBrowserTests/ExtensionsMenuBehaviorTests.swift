import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// The Extensions bubble behaves like Chrome's legacy `ExtensionsMenuView` and its
/// `ExtensionContextMenuModel`: the context menu's order, pin keeping the bubble open, other
/// choices closing it, and arrow-key traversal of the bubble's buttons.
@MainActor @Suite(.serialized) struct ExtensionsMenuBehaviorTests {
    final class Recorder: ExtensionMenuHandling {
        var performed: [(ExtensionMenuOperation, String?)] = []
        func title(for operation: ExtensionMenuOperation) -> String { operation.rawValue }
        func perform(_ operation: ExtensionMenuOperation, extensionID: String?) { performed.append((operation, extensionID)) }
    }

    static func info(id: String = "abc", location: BrowserExtensionInfo.Location = .webstore, hasAction: Bool = true,
                     pinned: Bool = false, options: Bool = true) -> BrowserExtensionInfo {
        BrowserExtensionInfo(id: id, name: "Extension \(id)", location: location, hasAction: hasAction, isPinned: pinned,
                             optionsURL: options ? URL(string: "chrome-extension://\(id)/options.html") : nil)
    }

    @Test func theToolbarContextMenuHasChromesOrder() {
        let model = ExtensionContextMenuModel(info: Self.info(), supportsManagement: true, source: .toolbarAction)
        #expect(model.items == [.name("Extension abc", enabled: true), .separator, .siteData, .separator, .options, .remove,
                                .pin(true), .separator, .manageExtension, .viewWebPermissions])
    }

    @Test func theBubblesContextMenuOffersUnpinAndAnUnpackedNameIsDisabled() {
        let model = ExtensionContextMenuModel(info: Self.info(location: .unpacked, pinned: true), supportsManagement: true,
                                              source: .menuItem)
        #expect(model.items == [.name("Extension abc", enabled: false), .separator, .siteData, .separator, .options, .remove,
                                .pin(false), .separator, .manageExtension, .viewWebPermissions])
    }

    @Test func anExtensionWithoutActionOrOptionsDropsThoseRows() {
        let model = ExtensionContextMenuModel(info: Self.info(hasAction: false, options: false), supportsManagement: true,
                                              source: .toolbarAction)
        #expect(model.items == [.name("Extension abc", enabled: true), .separator, .remove, .separator, .manageExtension,
                                .viewWebPermissions])
    }

    @Test func eachMenuRowRunsItsOperation() throws {
        let recorder = Recorder()
        let model = ExtensionContextMenuModel(info: Self.info(), supportsManagement: true, source: .toolbarAction)
        let menu = model.menu(extensionID: "abc", title: "Extension abc", handler: recorder)
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            == ["Extension abc", "-", Strings.extensionContextSiteData, "-", Strings.extensionMenuTitle(.options),
                Strings.extensionContextRemove, Strings.extensionMenuPinTooltip, "-", Strings.extensionContextManageExtension,
                Strings.extensionContextViewWebPermissions])
        // As a click does (`performActionForItem` needs a running NSApplication).
        for item in menu.items where item.isEnabled && !item.isSeparatorItem {
            let target = try #require(item.target as? NSObject)
            _ = target.perform(try #require(item.action), with: item)
        }
        #expect(recorder.performed.map(\.0) == [.homePage, .siteAccess, .options, .remove, .pin, .manageExtension, .webPermissions])
        #expect(recorder.performed.allSatisfy { $0.1 == "abc" })
    }

    @Test(.enabled("a bubble needs a screen to show") { await ExtensionsMenuPerformanceTests.hasDisplay() })
    func pinningKeepsTheBubbleOpenAndManageClosesIt() throws {
        let tab = ExtensionsMenuPerformanceTests.tab(extensions: 3)
        let (window, anchor) = ExtensionsMenuPerformanceTests.window()
        defer { window.close() }
        let recorder = Recorder()
        let controller = ExtensionsMenuController()
        controller.show(host: tab, handler: recorder, anchor: anchor)
        try #require(controller.isShown, "\(ExtensionsMenuPerformanceTests.environment(window))")
        let unpinned = try #require(controller.content.rows.first { !$0.isPinned })
        #expect(controller.choose("pin", extension: unpinned.extensionID))
        #expect(controller.isShown, "pinning closed the bubble")
        #expect(recorder.performed.last?.0 == .pin)
        #expect(controller.choose("manage", extension: nil))
        #expect(!controller.isShown)
        #expect(recorder.performed.last?.0 == .manage)
    }

    @Test(.enabled("a bubble needs a screen to show") { await ExtensionsMenuPerformanceTests.hasDisplay() })
    func theArrowKeysWalkTheBubblesButtonsAndWrap() throws {
        let tab = ExtensionsMenuPerformanceTests.tab(extensions: 2)
        let (window, anchor) = ExtensionsMenuPerformanceTests.window()
        defer { window.close() }
        let controller = ExtensionsMenuController()
        controller.show(host: tab, handler: Recorder(), anchor: anchor)
        try #require(controller.isShown, "\(ExtensionsMenuPerformanceTests.environment(window))")
        let order = controller.content.focusOrder
        // Two rows of three buttons, Manage Extensions, Get Extensions, close.
        #expect(order.count == 9)
        controller.moveFocus(by: 1)
        #expect(controller.focusedButton === order[0])
        controller.moveFocus(by: 1)
        #expect(controller.focusedButton === order[1])
        controller.moveFocus(by: -2)
        #expect(controller.focusedButton === order.last, "the keys did not wrap")
        controller.close()
    }
}
