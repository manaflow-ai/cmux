@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// u2320: a Chromium tab whose page asks for Widevine (or PlayReady, FairPlay) and is refused
/// reopens in WebKit at the same address, once; a pinned engine or Clear Key does not.
@Suite struct BrowserProtectedMediaTests {
    @Test(arguments: ["com.widevine.alpha", "com.widevine.alpha.experiment", "com.microsoft.playready.recommendation",
                      "com.apple.fps.1_0", "COM.WIDEVINE.ALPHA"])
    func aProtectedKeySystemNeedsAnotherEngine(keySystem: String) {
        #expect(BrowserProtectedMedia(keySystem: keySystem).needsAnotherEngine)
    }

    @Test(arguments: ["org.w3.clearkey", "com.widevine.alphabet", ""])
    func clearKeyAndUnknownNamesDoNot(keySystem: String) {
        #expect(!BrowserProtectedMedia(keySystem: keySystem).needsAnotherEngine)
    }

    @Test func aRefusedChromiumTabReopensInWebKitOnce() {
        let widevine = BrowserProtectedMedia(keySystem: "com.widevine.alpha")
        #expect(widevine.reopensInWebKit(engineIsChromium: true, enginePinned: false, alreadyReopened: false))
        #expect(!widevine.reopensInWebKit(engineIsChromium: true, enginePinned: false, alreadyReopened: true))
        #expect(!widevine.reopensInWebKit(engineIsChromium: true, enginePinned: true, alreadyReopened: false))
        #expect(!widevine.reopensInWebKit(engineIsChromium: false, enginePinned: false, alreadyReopened: false))
        #expect(!BrowserProtectedMedia(keySystem: "org.w3.clearkey")
            .reopensInWebKit(engineIsChromium: true, enginePinned: false, alreadyReopened: false))
    }

    @Test func theRelayBindingCallGivesTheKeySystem() {
        let call = #"{"method":"Runtime.bindingCalled","params":{"name":"cmuxProtectedMedia","payload":"com.widevine.alpha","executionContextId":7}}"#
        #expect(BrowserProtectedMedia.refused(bindingCall: call) == BrowserProtectedMedia(keySystem: "com.widevine.alpha"))
        let other = #"{"method":"Runtime.bindingCalled","params":{"name":"cmuxMedia","payload":"cmuxProtectedMedia"}}"#
        #expect(BrowserProtectedMedia.refused(bindingCall: other) == nil)
        let empty = #"{"method":"Runtime.bindingCalled","params":{"name":"cmuxProtectedMedia","payload":""}}"#
        #expect(BrowserProtectedMedia.refused(bindingCall: empty) == nil)
    }

    /// Runs the real probe in a page whose key-system request is refused, as Chromium refuses
    /// Widevine, and waits for the probe's event: the refused key system is on `<html>`.
    @MainActor @Test func theProbeReportsARefusedWidevineRequest() async throws {
        let view = WKWebView(frame: .zero)
        _ = try await view.callAsyncJavaScript("""
            Navigator.prototype.requestMediaKeySystemAccess = function (name) {
              return Promise.reject(new DOMException("Unsupported keySystem", "NotSupportedError"));
            };
            return true;
            """, contentWorld: .page)
        _ = try await view.evaluateJavaScript(BrowserProtectedMedia.probeScript + ";true")
        let reported = try await view.callAsyncJavaScript("""
            const heard = new Promise((resolve) => document.addEventListener("\(BrowserProtectedMedia.event)", resolve, { once: true }));
            navigator.requestMediaKeySystemAccess("com.widevine.alpha", [{}]).catch(() => {});
            await heard;
            return document.documentElement.getAttribute("\(BrowserProtectedMedia.attribute)");
            """, contentWorld: .page)
        #expect(reported as? String == "com.widevine.alpha")
    }

    /// A page that is granted one protected configuration is not reported for a refused one.
    @MainActor @Test func theProbeStaysQuietWhenARequestIsGranted() async throws {
        let view = WKWebView(frame: .zero)
        _ = try await view.callAsyncJavaScript("""
            Navigator.prototype.requestMediaKeySystemAccess = function (name, configs) {
              return configs.length ? Promise.resolve({ keySystem: name }) : Promise.reject(new Error("no"));
            };
            return true;
            """, contentWorld: .page)
        _ = try await view.evaluateJavaScript(BrowserProtectedMedia.probeScript + ";true")
        let attribute = try await view.callAsyncJavaScript("""
            await navigator.requestMediaKeySystemAccess("com.widevine.alpha", [{}]);
            await navigator.requestMediaKeySystemAccess("com.widevine.alpha", []).catch(() => {});
            await new Promise((resolve) => setTimeout(resolve, 1700));
            return document.documentElement.getAttribute("\(BrowserProtectedMedia.attribute)") ?? "none";
            """, contentWorld: .page)
        #expect(attribute as? String == "none")
    }
}
