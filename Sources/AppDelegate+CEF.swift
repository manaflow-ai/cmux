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
        let flag = BrowserEngineKind.current
        let avail = BrowserEngineKind.isCEFAvailable
        #if DEBUG
        cmuxDebugLog("cef.startup.check flag=\(flag.rawValue) available=\(avail)")
        #endif
        guard flag == .cef, avail else { return }
        #if canImport(CMUXCEF)
        if CEFEngine.shared.isRunning { return }
        guard let runtime = CEFRuntimeLocator.resolvedLocation() else {
            #if DEBUG
            cmuxDebugLog("cef.runtime.missing result=fallback_wkwebview")
            #endif
            NSLog("cmux: CEF runtime is not installed")
            return
        }

        // dlopen the CEF framework with RTLD_NOW | RTLD_GLOBAL so all
        // libcef exports are bound BEFORE any inline `CefString::FromString`
        // call in the bridge fires. Xcode's standard `-framework` link
        // doesn't pull C-export symbols into the dylib's lazy import table,
        // so the bridge would otherwise jump to PC=0 on the first CefString
        // operation.
        let cefFw = runtime.frameworkBinaryURL.path
        if dlopen(cefFw, RTLD_NOW | RTLD_GLOBAL) == nil {
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
            #if DEBUG
            let supportNamespace = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.debug"
            #else
            let supportNamespace = "cmux"
            #endif
            let root = support
                .appendingPathComponent(supportNamespace, isDirectory: true)
                .appendingPathComponent("CEFRoot", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)

            // `CEFEngineConfig.frameworkDirectoryPath` is interpreted by the
            // bridge as the *parent* directory; it appends
            // `Chromium Embedded Framework.framework`. Pass the bundle's
            // Frameworks directory, not the framework itself.
            let frameworksDir = runtime.frameworksDirectory
            let bundledFrameworksDir = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Frameworks", isDirectory: true)
            let bundledHelperExec = bundledFrameworksDir
                .appendingPathComponent("cmux Helper.app", isDirectory: true)
                .appendingPathComponent("Contents/MacOS/cmux Helper")
            let runtimeHelperExec = runtime.helperExecutableURL
            let helperExec = FileManager.default.isExecutableFile(atPath: bundledHelperExec.path)
                ? bundledHelperExec
                : runtimeHelperExec
            guard FileManager.default.isExecutableFile(atPath: helperExec.path) else {
                #if DEBUG
                cmuxDebugLog("cef.helper.missing path=\(helperExec.path)")
                #endif
                NSLog("cmux: CEF helper executable is missing at \(helperExec.path)")
                return
            }

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
