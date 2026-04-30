import CMUXCore
import XCTest

final class SocketMethodTests: XCTestCase {
    func testKnownWorkspaceMethodsKeepWireNames() throws {
        XCTAssertEqual(SocketMethod.workspaceList.rawValue, "workspace.list")
        XCTAssertEqual(SocketMethod.workspaceCreate.rawValue, "workspace.create")
        XCTAssertEqual(SocketMethod.workspaceSelect.rawValue, "workspace.select")
        XCTAssertEqual(SocketMethod.workspaceCurrent.rawValue, "workspace.current")
        XCTAssertEqual(SocketMethod.workspaceClose.rawValue, "workspace.close")
        XCTAssertEqual(SocketMethod.workspaceMoveToWindow.rawValue, "workspace.move_to_window")
        XCTAssertEqual(SocketMethod.workspaceRename.rawValue, "workspace.rename")
        XCTAssertEqual(SocketMethod.workspaceReorder.rawValue, "workspace.reorder")
        XCTAssertEqual(SocketMethod.workspaceAction.rawValue, "workspace.action")
        XCTAssertEqual(SocketMethod.workspaceRemoteConfigure.rawValue, "workspace.remote.configure")
        XCTAssertEqual(SocketMethod.workspaceRemoteStatus.rawValue, "workspace.remote.status")
        XCTAssertEqual(SocketMethod.workspaceRemoteTerminalSessionEnd.rawValue, "workspace.remote.terminal_session_end")
    }

    func testKnownSystemMethodsKeepWireNames() throws {
        XCTAssertEqual(SocketMethod.systemPing.rawValue, "system.ping")
        XCTAssertEqual(SocketMethod.systemCapabilities.rawValue, "system.capabilities")
        XCTAssertEqual(SocketMethod.systemIdentify.rawValue, "system.identify")
        XCTAssertEqual(SocketMethod.systemTree.rawValue, "system.tree")
    }

    func testKnownUtilityMethodsKeepWireNames() throws {
        XCTAssertEqual(SocketMethod.authStatus.rawValue, "auth.status")
        XCTAssertEqual(SocketMethod.authBeginSignIn.rawValue, "auth.begin_sign_in")
        XCTAssertEqual(SocketMethod.authSignOut.rawValue, "auth.sign_out")
        XCTAssertEqual(SocketMethod.markdownOpen.rawValue, "markdown.open")
        XCTAssertEqual(SocketMethod.feedbackOpen.rawValue, "feedback.open")
        XCTAssertEqual(SocketMethod.feedbackSubmit.rawValue, "feedback.submit")
        XCTAssertEqual(SocketMethod.settingsOpen.rawValue, "settings.open")
        XCTAssertEqual(SocketMethod.tabAction.rawValue, "tab.action")
    }

    func testKnownTerminalMethodsKeepWireNames() throws {
        XCTAssertEqual(SocketMethod.surfaceList.rawValue, "surface.list")
        XCTAssertEqual(SocketMethod.surfaceFocus.rawValue, "surface.focus")
        XCTAssertEqual(SocketMethod.surfaceSendText.rawValue, "surface.send_text")
        XCTAssertEqual(SocketMethod.surfaceSendKey.rawValue, "surface.send_key")
        XCTAssertEqual(SocketMethod.surfaceMove.rawValue, "surface.move")
        XCTAssertEqual(SocketMethod.surfaceReorder.rawValue, "surface.reorder")
        XCTAssertEqual(SocketMethod.surfaceTriggerFlash.rawValue, "surface.trigger_flash")
        XCTAssertEqual(SocketMethod.surfaceClearHistory.rawValue, "surface.clear_history")
        XCTAssertEqual(SocketMethod.paneList.rawValue, "pane.list")
        XCTAssertEqual(SocketMethod.paneFocus.rawValue, "pane.focus")
        XCTAssertEqual(SocketMethod.paneBreak.rawValue, "pane.break")
    }

    func testKnownBrowserMethodsKeepWireNames() throws {
        XCTAssertEqual(SocketMethod.browserURLGet.rawValue, "browser.url.get")
        XCTAssertEqual(SocketMethod.browserGetTitle.rawValue, "browser.get.title")
        XCTAssertEqual(SocketMethod.browserNavigate.rawValue, "browser.navigate")
        XCTAssertEqual(SocketMethod.browserOpenSplit.rawValue, "browser.open_split")
        XCTAssertEqual(SocketMethod.browserIsWebViewFocused.rawValue, "browser.is_webview_focused")
        XCTAssertEqual(SocketMethod.browserSnapshot.rawValue, "browser.snapshot")
        XCTAssertEqual(SocketMethod.browserEval.rawValue, "browser.eval")
        XCTAssertEqual(SocketMethod.browserWait.rawValue, "browser.wait")
        XCTAssertEqual(SocketMethod.browserBack.rawValue, "browser.back")
        XCTAssertEqual(SocketMethod.browserForward.rawValue, "browser.forward")
        XCTAssertEqual(SocketMethod.browserReload.rawValue, "browser.reload")
        XCTAssertEqual(SocketMethod.browserClick.rawValue, "browser.click")
        XCTAssertEqual(SocketMethod.browserDblClick.rawValue, "browser.dblclick")
        XCTAssertEqual(SocketMethod.browserHover.rawValue, "browser.hover")
        XCTAssertEqual(SocketMethod.browserCheck.rawValue, "browser.check")
        XCTAssertEqual(SocketMethod.browserUncheck.rawValue, "browser.uncheck")
        XCTAssertEqual(SocketMethod.browserScrollIntoView.rawValue, "browser.scroll_into_view")
        XCTAssertEqual(SocketMethod.browserType.rawValue, "browser.type")
        XCTAssertEqual(SocketMethod.browserFill.rawValue, "browser.fill")
        XCTAssertEqual(SocketMethod.browserPress.rawValue, "browser.press")
        XCTAssertEqual(SocketMethod.browserKeyDown.rawValue, "browser.keydown")
        XCTAssertEqual(SocketMethod.browserKeyUp.rawValue, "browser.keyup")
        XCTAssertEqual(SocketMethod.browserSelect.rawValue, "browser.select")
        XCTAssertEqual(SocketMethod.browserScroll.rawValue, "browser.scroll")
        XCTAssertEqual(SocketMethod.browserGetText.rawValue, "browser.get.text")
        XCTAssertEqual(SocketMethod.browserGetHTML.rawValue, "browser.get.html")
        XCTAssertEqual(SocketMethod.browserGetValue.rawValue, "browser.get.value")
        XCTAssertEqual(SocketMethod.browserGetAttr.rawValue, "browser.get.attr")
        XCTAssertEqual(SocketMethod.browserGetCount.rawValue, "browser.get.count")
        XCTAssertEqual(SocketMethod.browserGetBox.rawValue, "browser.get.box")
        XCTAssertEqual(SocketMethod.browserGetStyles.rawValue, "browser.get.styles")
        XCTAssertEqual(SocketMethod.browserIsVisible.rawValue, "browser.is.visible")
        XCTAssertEqual(SocketMethod.browserIsEnabled.rawValue, "browser.is.enabled")
        XCTAssertEqual(SocketMethod.browserIsChecked.rawValue, "browser.is.checked")
        XCTAssertEqual(SocketMethod.browserFindRole.rawValue, "browser.find.role")
        XCTAssertEqual(SocketMethod.browserFindNth.rawValue, "browser.find.nth")
        XCTAssertEqual(SocketMethod.browserScreenshot.rawValue, "browser.screenshot")
        XCTAssertEqual(SocketMethod.browserFrameMain.rawValue, "browser.frame.main")
        XCTAssertEqual(SocketMethod.browserFrameSelect.rawValue, "browser.frame.select")
        XCTAssertEqual(SocketMethod.browserDialogAccept.rawValue, "browser.dialog.accept")
        XCTAssertEqual(SocketMethod.browserDialogDismiss.rawValue, "browser.dialog.dismiss")
        XCTAssertEqual(SocketMethod.browserDownloadWait.rawValue, "browser.download.wait")
        XCTAssertEqual(SocketMethod.browserCookiesGet.rawValue, "browser.cookies.get")
        XCTAssertEqual(SocketMethod.browserCookiesSet.rawValue, "browser.cookies.set")
        XCTAssertEqual(SocketMethod.browserCookiesClear.rawValue, "browser.cookies.clear")
        XCTAssertEqual(SocketMethod.browserStorageGet.rawValue, "browser.storage.get")
        XCTAssertEqual(SocketMethod.browserStorageSet.rawValue, "browser.storage.set")
        XCTAssertEqual(SocketMethod.browserStorageClear.rawValue, "browser.storage.clear")
        XCTAssertEqual(SocketMethod.browserTabList.rawValue, "browser.tab.list")
        XCTAssertEqual(SocketMethod.browserTabNew.rawValue, "browser.tab.new")
        XCTAssertEqual(SocketMethod.browserTabSwitch.rawValue, "browser.tab.switch")
        XCTAssertEqual(SocketMethod.browserTabClose.rawValue, "browser.tab.close")
        XCTAssertEqual(SocketMethod.browserConsoleList.rawValue, "browser.console.list")
        XCTAssertEqual(SocketMethod.browserConsoleClear.rawValue, "browser.console.clear")
        XCTAssertEqual(SocketMethod.browserStateSave.rawValue, "browser.state.save")
        XCTAssertEqual(SocketMethod.browserStateLoad.rawValue, "browser.state.load")
        XCTAssertEqual(SocketMethod.browserTraceStart.rawValue, "browser.trace.start")
        XCTAssertEqual(SocketMethod.browserTraceStop.rawValue, "browser.trace.stop")
        XCTAssertEqual(SocketMethod.browserScreencastStart.rawValue, "browser.screencast.start")
        XCTAssertEqual(SocketMethod.browserScreencastStop.rawValue, "browser.screencast.stop")
        XCTAssertEqual(SocketMethod.browserInputMouse.rawValue, "browser.input_mouse")
        XCTAssertEqual(SocketMethod.browserInputKeyboard.rawValue, "browser.input_keyboard")
        XCTAssertEqual(SocketMethod.browserInputTouch.rawValue, "browser.input_touch")
        XCTAssertEqual(SocketMethod.browserErrorsList.rawValue, "browser.errors.list")
        XCTAssertEqual(SocketMethod.browserHighlight.rawValue, "browser.highlight")
        XCTAssertEqual(SocketMethod.browserViewportSet.rawValue, "browser.viewport.set")
        XCTAssertEqual(SocketMethod.browserGeolocationSet.rawValue, "browser.geolocation.set")
        XCTAssertEqual(SocketMethod.browserOfflineSet.rawValue, "browser.offline.set")
        XCTAssertEqual(SocketMethod.browserNetworkRoute.rawValue, "browser.network.route")
        XCTAssertEqual(SocketMethod.browserNetworkUnroute.rawValue, "browser.network.unroute")
        XCTAssertEqual(SocketMethod.browserNetworkRequests.rawValue, "browser.network.requests")
    }

    func testBrowserCommandMethodRegistryMapsAliases() throws {
        XCTAssertEqual(BrowserCommandMethod.history("back"), .browserBack)
        XCTAssertEqual(BrowserCommandMethod.history("forward"), .browserForward)
        XCTAssertEqual(BrowserCommandMethod.history("reload"), .browserReload)
        XCTAssertEqual(BrowserCommandMethod.elementAction("scrollinto"), .browserScrollIntoView)
        XCTAssertEqual(BrowserCommandMethod.elementAction("scroll-into-view"), .browserScrollIntoView)
        XCTAssertEqual(BrowserCommandMethod.keyboardAction("key"), .browserPress)
        XCTAssertEqual(BrowserCommandMethod.getter("html"), .browserGetHTML)
        XCTAssertEqual(BrowserCommandMethod.predicate("checked"), .browserIsChecked)
    }

    func testBrowserCommandMethodRegistryRejectsUnknownCommands() throws {
        XCTAssertNil(BrowserCommandMethod.history("open"))
        XCTAssertNil(BrowserCommandMethod.elementAction("tap"))
        XCTAssertNil(BrowserCommandMethod.keyboardAction("keypress"))
        XCTAssertNil(BrowserCommandMethod.getter("title"))
        XCTAssertNil(BrowserCommandMethod.predicate("hidden"))
    }

    func testKnownFocusIntentMethodsKeepWireNames() throws {
        XCTAssertEqual(SocketMethod.windowFocus.rawValue, "window.focus")
        XCTAssertEqual(SocketMethod.workspaceSelect.rawValue, "workspace.select")
        XCTAssertEqual(SocketMethod.surfaceFocus.rawValue, "surface.focus")
        XCTAssertEqual(SocketMethod.paneLast.rawValue, "pane.last")
        XCTAssertEqual(SocketMethod.browserFocusWebView.rawValue, "browser.focus_webview")
        XCTAssertEqual(SocketMethod.browserTabSwitch.rawValue, "browser.tab.switch")
        XCTAssertEqual(SocketMethod.debugCommandPaletteToggle.rawValue, "debug.command_palette.toggle")
        XCTAssertEqual(SocketMethod.debugNotificationFocus.rawValue, "debug.notification.focus")
        XCTAssertEqual(SocketMethod.debugAppActivate.rawValue, "debug.app.activate")
        XCTAssertEqual(SocketMethod.debugTerminals.rawValue, "debug.terminals")
        XCTAssertEqual(SocketMethod.feedJump.rawValue, "feed.jump")
    }

    func testCustomMethodRejectsEmptyWireName() throws {
        XCTAssertNil(SocketMethod(rawValue: ""))
        XCTAssertNil(SocketMethod(rawValue: "   "))
    }

    func testCustomMethodPreservesValidWireName() throws {
        XCTAssertEqual(SocketMethod(rawValue: "workspace.remote.status")?.rawValue, "workspace.remote.status")
    }

    func testDecodingRejectsPaddedWireName() throws {
        let data = #"" workspace.list ""#.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(SocketMethod.self, from: data))
    }
}
