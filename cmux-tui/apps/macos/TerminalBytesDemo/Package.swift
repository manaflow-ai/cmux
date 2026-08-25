// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let tuiRoot = packageDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let package = Package(
    name: "TerminalBytesDemo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TerminalBytesDemo", targets: ["TerminalBytesDemo"]),
    ],
    targets: [
        .systemLibrary(name: "CCmuxTerminal", path: "Sources/CCmuxTerminal"),
        .executableTarget(
            name: "TerminalBytesDemo",
            dependencies: ["CCmuxTerminal"],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags(
                    ["-L\(tuiRoot.path)/target/debug"],
                    .when(configuration: .debug)
                ),
                .unsafeFlags(
                    ["-L\(tuiRoot.path)/target/release"],
                    .when(configuration: .release)
                ),
                .linkedLibrary("cmux_terminal_client"),
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(name: "TerminalBytesDemoTests", dependencies: ["TerminalBytesDemo"]),
    ]
)
