import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// Task p01-process-063 of plans/cmux-next/chrome-parity/p01-process.md: with feature `chromiumPageDialogs`
/// a page's alert, confirm, prompt (JS_DIALOG) and HTTP authentication (AUTH) ask in the tab's prompt list,
/// which cmux shows as a `CmuxDialogSpec`, and each answer goes back to the shim by token once. Against a spy
/// shim, with the events the shim sends (CEFShim/src/page_dialog_state.h writes their strings).
@MainActor @Suite(.serialized) struct CEFPageDialogsTests {
    // MARK: Wire

    @Test func aJSDialogCarriesItsKindTextAndFrame() {
        let prompt = CEFShimEvent(kind: 61, browser: 7, request: 3, a: 2, b: 0, s1: "Name?",
                                  s2: "https://a.example:8443/form\nAda\nLovelace")
        #expect(prompt == .jsDialog(browser: 7, token: 3, dialog: CEFJSDialog(kind: .prompt, message: "Name?",
                                                                             defaultText: "Ada\nLovelace",
                                                                             frameURL: "https://a.example:8443/form")))
        let alert = CEFShimEvent(kind: 61, browser: 7, request: 4, a: 0, b: 0, s1: "Hi", s2: "https://a.example/\n")
        #expect(alert == .jsDialog(browser: 7, token: 4, dialog: CEFJSDialog(kind: .alert, message: "Hi", frameURL: "https://a.example/")))
        #expect(CEFShimEvent(kind: 62, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "") == .jsDialogsDismissed(browser: 7))
        // A kind CEF does not have still asks, so the page gets an answer.
        let odd = CEFShimEvent(kind: 61, browser: 7, request: 5, a: 9, b: 0, s1: "?", s2: "")
        #expect(odd == .jsDialog(browser: 7, token: 5, dialog: CEFJSDialog(kind: .alert, message: "?", frameURL: "")))
    }

    @Test func theTitleNamesTheFramesOrigin() {
        func origin(_ url: String) -> String { CEFJSDialog(kind: .alert, message: "", frameURL: url).displayOrigin }
        #expect(origin("https://a.example/x?y=1") == "https://a.example")
        #expect(origin("https://a.example:443/") == "https://a.example")
        #expect(origin("http://a.example:8080/") == "http://a.example:8080")
        #expect(origin("file:///tmp/page.html") == "file://")
    }

    @Test func anAuthChallengeNamesWebKitsProtectionSpace() {
        let event = CEFShimEvent(kind: 63, browser: 7, request: 8, a: 8443, b: 0, s1: "intranet.example",
                                 s2: "https://intranet.example:8443/\nbasic\nStaff\nonly")
        let challenge = CEFAuthChallenge(host: "intranet.example", port: 8443, isProxy: false, originURL: "https://intranet.example:8443/",
                                         scheme: "basic", realm: "Staff\nonly")
        #expect(event == .auth(browser: 7, token: 8, challenge: challenge))
        let space = challenge.protectionSpace
        #expect(space.host == "intranet.example" && space.port == 8443 && space.protocol == NSURLProtectionSpaceHTTPS)
        #expect(space.realm == "Staff\nonly" && space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic && !space.isProxy())

        let proxy = CEFAuthChallenge(host: "proxy.example", port: 3128, flags: 1, details: "http://a.example/\ndigest\n")
        #expect(proxy.isProxy && proxy.realm.isEmpty)
        #expect(proxy.protectionSpace.isProxy() && proxy.protectionSpace.realm == nil)
        #expect(proxy.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest)
        #expect(CEFShimEvent(kind: 64, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "") == .authDismissed(browser: 7))
    }

    // MARK: The tab asks

    @Test func aConfirmAsksInTheTabAndItsAnswerReachesThePage() throws {
        let rig = try DialogRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.runtime.handle(.jsDialog(browser: 7, token: 11, dialog: CEFJSDialog(kind: .confirm, message: "Leave?", frameURL: "https://a.example/x")))
        let prompt = try #require(tab.pendingPrompts.first)
        #expect(prompt.kind == .confirm(message: "Leave?") && prompt.origin == "https://a.example")
        prompt.respond(.accept)
        #expect(DialogSpy.dialogReplies == [DialogSpy.DialogReply(token: 11, accept: 1, text: nil)])
        #expect(tab.pendingPrompts.isEmpty)
    }

    @Test func aPromptAnswersWithItsTextAndCancelWithNothing() throws {
        let rig = try DialogRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.runtime.handle(.jsDialog(browser: 7, token: 12, dialog: CEFJSDialog(kind: .prompt, message: "Name?", defaultText: "Ada",
                                                                              frameURL: "https://a.example/")))
        let prompt = try #require(tab.pendingPrompts.first)
        #expect(prompt.kind == .textInput(message: "Name?", defaultText: "Ada"))
        prompt.respond(.text("Grace"))
        rig.runtime.handle(.jsDialog(browser: 7, token: 13, dialog: CEFJSDialog(kind: .prompt, message: "Again?", frameURL: "https://a.example/")))
        try #require(tab.pendingPrompts.first).respond(.cancel)
        #expect(DialogSpy.dialogReplies == [DialogSpy.DialogReply(token: 12, accept: 1, text: "Grace"),
                                            DialogSpy.DialogReply(token: 13, accept: 0, text: nil)])
    }

    @Test func chromiumsResetTakesTheDialogAway() throws {
        let rig = try DialogRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.runtime.handle(.jsDialog(browser: 7, token: 14, dialog: CEFJSDialog(kind: .alert, message: "Hi", frameURL: "https://a.example/")))
        #expect(tab.pendingPrompts.count == 1)
        rig.runtime.handle(.jsDialogsDismissed(browser: 7))
        #expect(tab.pendingPrompts.isEmpty, "DevTools or a navigation answered it")
    }

    @Test func aQuestionWithNoTabIsCancelledAtOnce() throws {
        let rig = try DialogRig()
        defer { rig.close() }
        rig.runtime.handle(.jsDialog(browser: 99, token: 21, dialog: CEFJSDialog(kind: .confirm, message: "?", frameURL: "")))
        rig.runtime.handle(.auth(browser: 99, token: 22, challenge: Self.challenge))
        #expect(DialogSpy.dialogReplies == [DialogSpy.DialogReply(token: 21, accept: 0, text: nil)])
        #expect(DialogSpy.authReplies == [DialogSpy.AuthReply(token: 22, accept: 0, user: nil, password: nil)])
    }

    @Test func aSignInAsksAndSendsTheLogin() async throws {
        let rig = try DialogRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.runtime.handle(.auth(browser: 7, token: 31, challenge: Self.challenge))
        let prompt = try #require(await tab.whenPrompt(kind: { $0.isSignIn }, timeout: .seconds(5)))
        #expect(prompt.kind == .credentials(host: "intranet.example", realm: "Staff"))
        prompt.respond(.credentials(user: "ada", password: "secret"))
        #expect(DialogSpy.authReplies == [DialogSpy.AuthReply(token: 31, accept: 1, user: "ada", password: "secret")])

        rig.runtime.handle(.auth(browser: 7, token: 32, challenge: Self.challenge))
        try #require(await tab.whenPrompt(kind: { $0.isSignIn }, timeout: .seconds(5))).respond(.cancel)
        #expect(DialogSpy.authReplies.last == DialogSpy.AuthReply(token: 32, accept: 0, user: nil, password: nil))
    }

    @Test func aNewNavigationTakesTheSignInAway() async throws {
        let rig = try DialogRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        rig.runtime.handle(.auth(browser: 7, token: 33, challenge: Self.challenge))
        _ = try #require(await tab.whenPrompt(kind: { $0.isSignIn }, timeout: .seconds(5)))
        rig.runtime.handle(.authDismissed(browser: 7))
        #expect(tab.pendingPrompts.isEmpty)
    }

    /// A server that keeps refusing gets ``BrowserHTTPAuth/attemptLimit`` tries, then its own page loads,
    /// as WebKit's `previousFailureCount` stops a WebKit tab; a commit starts the count over.
    @Test func afterTheLastFailedTryTheServersPageLoads() async throws {
        let rig = try DialogRig()
        defer { rig.close() }
        let tab = try rig.attachedTab()
        for token in Int32(41)..<Int32(41 + BrowserHTTPAuth.attemptLimit) {
            rig.runtime.handle(.auth(browser: 7, token: token, challenge: Self.challenge))
            try #require(await tab.whenPrompt(kind: { $0.isSignIn }, timeout: .seconds(5))).respond(.credentials(user: "ada", password: "wrong"))
        }
        let stop = Int32(41 + BrowserHTTPAuth.attemptLimit)
        rig.runtime.handle(.auth(browser: 7, token: stop, challenge: Self.challenge))
        #expect(DialogSpy.authReplies.last == DialogSpy.AuthReply(token: stop, accept: 0, user: nil, password: nil))
        #expect(tab.pendingPrompts.isEmpty, "no question once the tries are used up")

        rig.runtime.handle(.loadStart(browser: 7, url: "https://intranet.example:8443/", fromPost: false))
        rig.runtime.handle(.auth(browser: 7, token: stop + 1, challenge: Self.challenge))
        #expect(await tab.whenPrompt(kind: { $0.isSignIn }, timeout: .seconds(5)) != nil, "the committed page's next challenge asks again")
    }

    static let challenge = CEFAuthChallenge(host: "intranet.example", port: 8443, isProxy: false, originURL: "https://intranet.example:8443/",
                                            scheme: "basic", realm: "Staff")

    // MARK: Rig

    @MainActor final class DialogRig {
        let runtime: CEFRuntime
        let root: URL

        init() throws {
            DialogSpy.reset()
            root = FileManager.default.temporaryDirectory.appending(path: "cef-page-dialogs-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(DialogSpy.symbol), storage: CEFProfileStorage(root: root))
        }

        /// A tab whose browser 7 exists (AFTER_CREATED).
        func attachedTab() throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(tab)
            host.ensureCreated(tab)
            let request = try #require(runtime.pendingWindows.keys.first)
            runtime.handle(.afterCreated(browser: 7, request: request, window: 1))
            try #require(tab.browserID == 7)
            return tab
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// A fake shim: `cmux_shim_js_dialog_reply` and `cmux_shim_auth_reply` record their answers; every other
/// function does nothing.
private nonisolated enum DialogSpy {
    nonisolated struct DialogReply: Equatable {
        var token: Int32
        var accept: Int32
        var text: String?
    }

    nonisolated struct AuthReply: Equatable {
        var token: Int32
        var accept: Int32
        var user: String?
        var password: String?
    }

    nonisolated(unsafe) static var dialogReplies: [DialogReply] = [] // crash-allow: the suite is serialized and the shim is called on the main actor
    nonisolated(unsafe) static var authReplies: [AuthReply] = [] // crash-allow: the suite is serialized and the shim is called on the main actor

    static func reset() {
        dialogReplies = []
        authReplies = []
    }

    // SAFETY (every `unsafe` below): each closure is a C function of its export's type in cmux_cef_shim.h; it reads
    // its string arguments only during the call, as the export's contract gives.
    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let version: @convention(c) () -> Int32 = { 31 }
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = {
            _, _, _, _, _, _ in 1
        }
        let dialogReply: @convention(c) (Int32, Int32, UnsafePointer<CChar>?) -> Int32 = { token, accept, text in
            DialogSpy.dialogReplies.append(DialogReply(token: token, accept: accept, text: unsafe text.map(String.init(cString:))))
            return 1
        }
        let authReply: @convention(c) (Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { token, accept, user, password in
            DialogSpy.authReplies.append(AuthReply(token: token, accept: accept, user: unsafe user.map(String.init(cString:)),
                                                   password: unsafe password.map(String.init(cString:))))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_fork_api_version": unsafeBitCast(version, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_js_dialog_reply": unsafeBitCast(dialogReply, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_auth_reply": unsafeBitCast(authReply, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
