@testable import CmuxNextBrowser
import Testing

/// alert, confirm and prompt of an in-tree Chromium page go to cmux's own dialog. The fork cancels a JavaScript
/// dialog of an in-tree page that no CEF handler takes (fork API 36): live step ff9c0eb4 on cmux19, in tree,
/// `alert()` showed nothing while with in-tree pages off Chromium's "… says" window showed. The shim now sends them
/// to the host as JS_DIALOG (53) and JS_DIALOG_DISMISSED (54); the tab asks with the same prompt as a WebKit tab.
@MainActor struct CEFJSDialogTests {
    @Test func theShimsDialogEventsDecode() {
        let asked = CEFShimEvent(kind: 53, browser: 7, request: 31, a: 2, b: 0,
                                 s1: "http://127.0.0.1:50631/page.html", s2: #"{"message":"Name?","default":"x"}"#)
        guard case .jsDialog(let browser, let token, let type, let origin, let text) = asked else {
            Issue.record("JS_DIALOG decoded as \(asked)")
            return
        }
        #expect(browser == 7 && token == 31 && type == 2)
        #expect(origin == "http://127.0.0.1:50631/page.html")
        #expect(text.contains("Name?"))
        #expect(asked.browserID == 7, "the event names its browser, so it reaches its tab")
        let dismissed = CEFShimEvent(kind: 54, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "")
        guard case .jsDialogDismissed(7) = dismissed else {
            Issue.record("JS_DIALOG_DISMISSED decoded as \(dismissed)")
            return
        }
    }

    @Test func eachTypeAsksItsOwnPrompt() {
        #expect(CEFJSDialogQuestion(type: 0, textJSON: #"{"message":"hi"}"#)?.kind == .alert(message: "hi"))
        #expect(CEFJSDialogQuestion(type: 1, textJSON: #"{"message":"sure?"}"#)?.kind == .confirm(message: "sure?"))
        #expect(CEFJSDialogQuestion(type: 2, textJSON: #"{"message":"Name?","default":"x"}"#)?.kind
            == .textInput(message: "Name?", defaultText: "x"))
        #expect(CEFJSDialogQuestion(type: 9, textJSON: #"{"message":"?"}"#) == nil)
        #expect(CEFJSDialogQuestion(type: 0, textJSON: "not json") == nil)
    }

    @Test func theAnswerReachesThePage() {
        #expect(CEFJSDialogQuestion.reply(.accept) == (true, ""))
        #expect(CEFJSDialogQuestion.reply(.text("Ada")) == (true, "Ada"))
        #expect(CEFJSDialogQuestion.reply(.cancel) == (false, ""))
        #expect(CEFJSDialogQuestion.reply(.deny) == (false, ""))
    }

    @Test func theDialogNamesTheOriginAsChromeDoes() {
        #expect(CEFTab.dialogOrigin("http://127.0.0.1:50631/page.html") == "127.0.0.1:50631")
        #expect(CEFTab.dialogOrigin("https://example.com/a/b?c") == "example.com")
        #expect(CEFTab.dialogOrigin("about:blank") == "about:blank")
    }

    @Test func onlyAlertConfirmAndPromptAreJavaScriptDialogs() {
        #expect(BrowserPromptKind.alert(message: "").isJavaScriptDialog)
        #expect(BrowserPromptKind.textInput(message: "", defaultText: nil).isJavaScriptDialog)
        #expect(!BrowserPromptKind.beforeUnload(isReload: false).isJavaScriptDialog)
    }
}
