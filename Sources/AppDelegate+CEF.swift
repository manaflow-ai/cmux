import AppKit
import Foundation

#if canImport(CMUXCEF)
import CMUXCEF
#endif

/// Boots the Chromium Embedded Framework runtime if (a) the `CMUXCEF`
/// SwiftPM package is linked into this build and (b) the user has
/// switched the browser engine flag to ``BrowserEngineKind/cef``.
///
/// Safe to call when CEF is not linked — the function is a no-op.
/// Engine errors are logged but never propagated; cmux continues to
/// run with WKWebView as the browser engine in that case.
///
/// Top-level free function so the CEF panel can lazily kick the engine
/// on mid-session flag flips without going through
/// `NSApp.delegate as? AppDelegate` — that cast fails under SwiftUI's
/// `NSApplicationDelegateAdaptor` and was silently swallowing the
/// lazy-start request, leaving the panel staring at
/// `CEFBrowserPanelError.engineNotStarted`.
@MainActor
func startCEFEngineIfNeeded() {
        // DIAGNOSTIC: redirect stderr to /tmp/cmux-cef-stderr.log so we can
        // inspect Chromium's --enable-logging=stderr output (the CEF engine
        // and all its helpers write to fd 2).
        #if DEBUG
        let stderrPath = "/tmp/cmux-cef-stderr.log"
        _ = freopen(stderrPath, "w", stderr)
        setvbuf(stderr, nil, _IOLBF, 0)
        cmuxDebugLog("cef.stderr.redirected path=\(stderrPath)")
        #endif
        let flag = BrowserEngineKind.current
        let avail = BrowserEngineKind.isCEFAvailable
        #if DEBUG
        cmuxDebugLog("cef.startup.check flag=\(flag.rawValue) available=\(avail)")
        #endif
        guard flag == .cef, avail else { return }
        #if canImport(CMUXCEF)
        if CEFEngine.shared.isRunning { return }
        // dlopen the CEF framework with RTLD_NOW | RTLD_GLOBAL so all
        // libcef exports are bound BEFORE any inline `CefString::FromString`
        // call in the bridge fires. Xcode's standard `-framework` link
        // doesn't pull C-export symbols into the dylib's lazy import table,
        // so the bridge would otherwise jump to PC=0 on the first CefString
        // operation.
        let cefFw = Bundle.main.bundleURL
            .appendingPathComponent(
                "Contents/Frameworks/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
            ).path
        if dlopen(cefFw, RTLD_LAZY | RTLD_GLOBAL) == nil {
            #if DEBUG
            let err = dlerror().map { String(cString: $0) } ?? "unknown"
            cmuxDebugLog("cef.dlopen.failed path=\(cefFw) err=\(err)")
            #endif
            NSLog("cmux: CEF dlopen failed at \(cefFw)")
            return
        }
        #if DEBUG
        cmuxDebugLog("cef.dlopen.ok path=\(cefFw)")
        #endif
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let root = support
                .appendingPathComponent("cmux", isDirectory: true)
                .appendingPathComponent("CEFRoot", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)

            // `CEFEngineConfig.frameworkDirectoryPath` is interpreted by the
            // bridge as the *parent* directory; it appends
            // `Chromium Embedded Framework.framework`. Pass the bundle's
            // Frameworks directory, not the framework itself.
            let frameworksDir = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Frameworks", isDirectory: true)
            let helperExec = frameworksDir
                .appendingPathComponent("cmux Helper.app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS/cmux Helper")

            #if DEBUG
            cmuxDebugLog("cef.engine.start.calling root=\(root.path) fwParent=\(frameworksDir.path) helper=\(helperExec.path)")
            #endif
            try CEFEngine.shared.start(config: CEFEngineConfig(
                rootCachePath: root,
                extensionDirectories: [],
                logSeverity: 0,
                userAgentProduct: "cmux",
                frameworkDirectoryPath: frameworksDir,
                browserSubprocessPath: helperExec))
            #if DEBUG
            cmuxDebugLog("cef.engine.started root=\(root.path) fwParent=\(frameworksDir.path) helper=\(helperExec.path)")
            #endif
        } catch {
            #if DEBUG
            cmuxDebugLog("cef.engine.start.failed error=\(error)")
            #endif
            NSLog("cmux: failed to start CEF engine: \(error)")
        }
        #endif
}
