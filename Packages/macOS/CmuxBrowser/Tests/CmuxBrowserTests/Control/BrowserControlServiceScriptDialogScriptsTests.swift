import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserControlService script/dialog scripts")
struct BrowserControlServiceScriptDialogScriptsTests {
    let service = BrowserControlService()

    @Test("addStyleScript emits the exact frozen wire script")
    func addStyleScriptExact() {
        // The browser RPC wire format is frozen; assert the full emitted script so
        // any drift in the page-world JS is caught. The caller passes the CSS as a
        // jsonLiteral, so the literal here is already a quoted JS string.
        let cssLiteral = service.jsonLiteral("body { color: red; }")
        let expected = """
        (() => {
          const el = document.createElement('style');
          el.textContent = String(\(cssLiteral));
          (document.head || document.documentElement || document.body).appendChild(el);
          return true;
        })()
        """
        #expect(service.addStyleScript(cssLiteral: cssLiteral) == expected)
    }

    @Test("dialogRespondScript emits the exact frozen wire script (accept with text)")
    func dialogRespondScriptAcceptWithText() {
        let textLiteral = service.jsonLiteral("hello")
        let expected = """
        (() => {
          const q = window.__cmuxDialogQueue || [];
          if (!q.length) return { ok: false, error: 'not_found' };
          const entry = q.shift();
          if (entry.type === 'confirm') {
            window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
            window.__cmuxDialogDefaults.confirm = true;
          }
          if (entry.type === 'prompt') {
            window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
            if (true) {
              window.__cmuxDialogDefaults.prompt = \(textLiteral);
            } else {
              window.__cmuxDialogDefaults.prompt = null;
            }
          }
          return { ok: true, dialog: entry, remaining: q.length };
        })()
        """
        #expect(service.dialogRespondScript(acceptLiteral: "true", textLiteral: textLiteral) == expected)
    }

    @Test("dialogRespondScript emits the exact frozen wire script (dismiss, null text)")
    func dialogRespondScriptDismissNullText() {
        let expected = """
        (() => {
          const q = window.__cmuxDialogQueue || [];
          if (!q.length) return { ok: false, error: 'not_found' };
          const entry = q.shift();
          if (entry.type === 'confirm') {
            window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
            window.__cmuxDialogDefaults.confirm = false;
          }
          if (entry.type === 'prompt') {
            window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
            if (false) {
              window.__cmuxDialogDefaults.prompt = null;
            } else {
              window.__cmuxDialogDefaults.prompt = null;
            }
          }
          return { ok: true, dialog: entry, remaining: q.length };
        })()
        """
        #expect(service.dialogRespondScript(acceptLiteral: "false", textLiteral: "null") == expected)
    }
}

@Suite("BrowserImportScope raw-token parsing")
struct BrowserImportScopeRawTokenTests {
    @Test("empty/whitespace/nil tokens resolve to .empty")
    func emptyTokens() {
        #expect(BrowserImportScope.from(rawToken: nil) == .empty)
        #expect(BrowserImportScope.from(rawToken: "") == .empty)
        #expect(BrowserImportScope.from(rawToken: "   \n\t") == .empty)
    }

    @Test("every legacy alias resolves to its scope, case/whitespace-insensitive")
    func aliasResolution() {
        for token in ["cookie", "cookies", "cookiesOnly", "cookies_only", "cookies-only", "  COOKIES  "] {
            #expect(BrowserImportScope.from(rawToken: token) == .scope(.cookiesOnly), "token=\(token)")
        }
        for token in ["history", "historyOnly", "history_only", "history-only"] {
            #expect(BrowserImportScope.from(rawToken: token) == .scope(.historyOnly), "token=\(token)")
        }
        for token in ["cookiesAndHistory", "cookies_and_history", "cookies-and-history", "all-basic"] {
            #expect(BrowserImportScope.from(rawToken: token) == .scope(.cookiesAndHistory), "token=\(token)")
        }
        for token in ["everything", "all"] {
            #expect(BrowserImportScope.from(rawToken: token) == .scope(.everything), "token=\(token)")
        }
    }

    @Test("unrecognized token resolves to .invalid")
    func invalidToken() {
        #expect(BrowserImportScope.from(rawToken: "bookmarks") == .invalid)
        #expect(BrowserImportScope.from(rawToken: "cookies+history") == .invalid)
    }
}
