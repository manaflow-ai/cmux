import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator helper build cache identity")
struct SimulatorBuildCacheIdentityTests {
    @Test("Camera cache key changes when a bundled header changes")
    func cameraHeaderInputs() async throws {
        let fileManager = FileManager.default
        let resources = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-camera-cache-\(UUID().uuidString)")
        let includeDirectory = resources.appendingPathComponent("include")
        try fileManager.createDirectory(at: includeDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: resources) }

        let sourceNames = [
            "SimCameraInjector.m.txt",
            "SimCamLog.m.txt",
            "SimCamFakes.m.txt",
            "SimCamFrameSource.m.txt",
            "SimCamSwizzles.m.txt",
        ]
        let token = UUID().uuidString
        for name in sourceNames {
            let source = "// cache identity \(token)\n"
            try Data(source.utf8).write(to: resources.appendingPathComponent(name))
        }
        for name in ["SimCamFakes.h", "SimCamFrameSource.h", "SimCamLog.h", "SimCamSwizzles.h"] {
            try Data("// header\n".utf8).write(to: resources.appendingPathComponent(name))
        }
        let sharedHeader = includeDirectory.appendingPathComponent("SimCamShared.h")
        try Data("#define CMUX_TEST_ABI 1\n".utf8).write(to: sharedHeader)

        let compiler = SimulatorCameraInjectorCompiler(resourceDirectory: resources)
        let firstLibrary = try await compiler.compiledLibrary()
        defer { try? fileManager.removeItem(at: firstLibrary.deletingLastPathComponent()) }

        try Data("#define CMUX_TEST_ABI 2\n".utf8).write(to: sharedHeader)
        let secondLibrary = try await compiler.compiledLibrary()
        defer {
            if secondLibrary != firstLibrary {
                try? fileManager.removeItem(at: secondLibrary.deletingLastPathComponent())
            }
        }

        #expect(firstLibrary != secondLibrary)
    }

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
