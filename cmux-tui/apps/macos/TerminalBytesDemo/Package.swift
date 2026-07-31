// swift-tools-version: 6.0
import PackageDescription

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
                .unsafeFlags(["-L../../../target/debug", "-lcmux_terminal_client"]),
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(name: "TerminalBytesDemoTests", dependencies: ["TerminalBytesDemo"]),
    ]
)
