import Foundation

struct SimulatorCameraInjectorCompiler: Sendable {
    private static let sourceNames = [
        "SimCameraInjector.m.txt",
        "SimCamLog.m.txt",
        "SimCamFakes.m.txt",
        "SimCamFrameSource.m.txt",
        "SimCamSwizzles.m.txt",
    ]
    private static let headerNames = [
        "SimCamFakes.h",
        "SimCamFrameSource.h",
        "SimCamLog.h",
        "SimCamSwizzles.h",
        "include/SimCamShared.h",
    ]
    private static let buildInputNames = sourceNames + headerNames
    private let subprocessRunner: SimulatorSubprocessRunner
    private let fileSystem: SimulatorCameraFileSystem
    private let resourceDirectory: URL?

    init(
        subprocessRunner: SimulatorSubprocessRunner = SimulatorSubprocessRunner(),
        fileSystem: SimulatorCameraFileSystem = SimulatorCameraFileSystem(),
        resourceDirectory: URL? = Bundle.module.resourceURL?.appendingPathComponent("CameraInjector")
    ) {
        self.subprocessRunner = subprocessRunner
        self.fileSystem = fileSystem
        self.resourceDirectory = resourceDirectory
    }

    func compiledLibrary() async throws -> URL {
        guard let resources = resourceDirectory,
              fileSystem.fileExists(atPath: resources.path)
        else {
            throw SimulatorWorkerFailure.frameworkUnavailable(
                "The bundled synthetic-camera injector sources are missing."
            )
        }
        let buildInputs: [SimulatorBuildSource] = try Self.buildInputNames.map { name in
            let url = resources.appendingPathComponent(name)
            guard let data = fileSystem.contents(atPath: url.path) else {
                throw SimulatorWorkerFailure.frameworkUnavailable(
                    "The bundled camera injector build input \(name) is missing."
                )
            }
            return SimulatorBuildSource(name: name, data: data)
        }
        let sdk = try await SimulatorSDKIdentityResolver { descriptor in
            try await subprocessRunner.run(
                executableURL: URL(fileURLWithPath: descriptor.executable),
                arguments: descriptor.arguments
            )
        }.resolve()
        let cacheKey = SimulatorBuildInputs(
            sources: buildInputs,
            compileArguments: compileArguments(
                sdkPath: "<SDKROOT>",
                resourcesPath: "<RESOURCE_ROOT>",
                outputPath: "<OUTPUT>",
                sourcePaths: Self.sourceNames.map { "<SOURCE:\($0)>" }
            ),
            sdk: sdk
        ).cacheKey
        let cacheRoot = try fileSystem.cachesDirectory()
            .appendingPathComponent("cmux/SimulatorCameraInjector/\(cacheKey)")
        let libraryURL = cacheRoot.appendingPathComponent("libCmuxSimulatorCameraInjector.dylib")
        if fileSystem.isReadableFile(atPath: libraryURL.path) {
            return libraryURL
        }
        try fileSystem.createDirectory(at: cacheRoot)

        let temporaryURL = cacheRoot.appendingPathComponent("injector-\(UUID().uuidString).dylib")
        let arguments = compileArguments(
            sdkPath: sdk.path,
            resourcesPath: resources.path,
            outputPath: temporaryURL.path,
            sourcePaths: Self.sourceNames.map { resources.appendingPathComponent($0).path }
        )
        let compileResult = try await subprocessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: arguments
        )
        guard compileResult.status == 0,
              fileSystem.isReadableFile(atPath: temporaryURL.path)
        else {
            try? fileSystem.removeItem(at: temporaryURL)
            throw SimulatorWorkerFailure.frameworkUnavailable(
                compileResult.standardError.isEmpty
                    ? "The synthetic-camera injector failed to compile."
                    : compileResult.standardError
            )
        }
        do {
            try fileSystem.moveItem(at: temporaryURL, to: libraryURL)
        } catch CocoaError.fileWriteFileExists {
            try? fileSystem.removeItem(at: temporaryURL)
        }
        return libraryURL
    }

    func compileArguments(
        sdkPath: String,
        resourcesPath: String,
        outputPath: String,
        sourcePaths: [String]
    ) -> [String] {
        [
            "--sdk", "iphonesimulator", "clang",
            "-arch", "arm64", "-arch", "x86_64",
            "-mios-simulator-version-min=15.0",
            "-isysroot", sdkPath,
            "-dynamiclib", "-fobjc-arc", "-fmodules", "-fobjc-weak",
            "-I", resourcesPath,
            "-framework", "Foundation",
            "-framework", "UIKit",
            "-framework", "AVFoundation",
            "-framework", "CoreImage",
            "-framework", "CoreMedia",
            "-framework", "CoreMotion",
            "-framework", "CoreVideo",
            "-framework", "CoreGraphics",
            "-framework", "IOSurface",
            "-framework", "QuartzCore",
            "-install_name", "@rpath/libCmuxSimulatorCameraInjector.dylib",
            "-o", outputPath,
            "-x", "objective-c",
        ] + sourcePaths
    }
}
