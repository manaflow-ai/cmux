import Foundation
import JavaScriptCore
import Testing
@testable import CmuxNextApps

/// The `__cmuxAppNative` blocks run on the engine's executor. Called from any
/// other thread they refuse (a fault log and a neutral result) instead of
/// trapping in `assumeIsolated` (plans/cmux-next/crash-elimination.md, P1b).
struct AppEngineExecutorTests {
    @Test func nativeCallsOffTheEngineExecutorRefuseInsteadOfTrapping() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "return {}")
        let output = OutputCollector()
        let engine = AppEngine(configuration: AppEngineConfiguration(
            manifest: manifest, bundleDirectory: directory, grants: AppGrants(.init(scopes: [])),
            sink: RecordingSink(), clock: ManualAppClock(), output: output.sink))
        let results = await withCheckedContinuation { (done: CheckedContinuation<[Double], Never>) in
            Thread.detachNewThread {
                guard let context = JSContext() else { return done.resume(returning: []) }
                engine.installNative(in: context)
                let timer = context.evaluateScript("__cmuxAppNative.timer(10, false)")?.toDouble() ?? -1
                let subscribe = context.evaluateScript("__cmuxAppNative.subscribe('agents', '')")?.toDouble() ?? -1
                context.evaluateScript("__cmuxAppNative.log('info', 'off the executor')")
                done.resume(returning: [timer, subscribe])
            }
        }
        #expect(results == [0, 0])
        #expect(output.logs.isEmpty)
    }
}
