import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator helper build cache identity")
struct SimulatorBuildCacheIdentityTests {
    @Test("Camera cache key covers source bytes, compile flags, and SDK identity")
    func cameraInputs() {
        let sdk = SimulatorSDKIdentity(
            path: "/Xcode/iPhoneSimulator.sdk",
            version: "26.0",
            buildVersion: "23A1",
            compilerVersion: "Apple clang 21",
            settingsDigest: "settings-one"
        )
        let arguments = SimulatorCameraInjectorCompiler().compileArguments(
            sdkPath: "<SDKROOT>",
            resourcesPath: "<RESOURCE_ROOT>",
            outputPath: "<OUTPUT>",
            sourcePaths: ["<SOURCE:injector>"]
        )
        let base = SimulatorBuildInputs(
            sources: [SimulatorBuildSource(name: "injector", data: Data("one".utf8))],
            compileArguments: arguments,
            sdk: sdk
        )
        let changedSource = SimulatorBuildInputs(
            sources: [SimulatorBuildSource(name: "injector", data: Data("two".utf8))],
            compileArguments: arguments,
            sdk: sdk
        )
        let changedFlags = SimulatorBuildInputs(
            sources: base.sources,
            compileArguments: arguments + ["-DCHANGED"],
            sdk: sdk
        )
        let changedSDK = SimulatorBuildInputs(
            sources: base.sources,
            compileArguments: arguments,
            sdk: SimulatorSDKIdentity(
                path: sdk.path,
                version: sdk.version,
                buildVersion: "23A2",
                compilerVersion: sdk.compilerVersion,
                settingsDigest: "settings-two"
            )
        )

        #expect(base.cacheKey != changedSource.cacheKey)
        #expect(base.cacheKey != changedFlags.cacheKey)
        #expect(base.cacheKey != changedSDK.cacheKey)
        #expect(base.cacheKey == base.cacheKey)
    }
}
