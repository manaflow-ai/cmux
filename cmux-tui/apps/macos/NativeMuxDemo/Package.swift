// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeMuxDemo",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NativeMuxDemo", targets: ["NativeMuxDemo"]),
    ],
    targets: [
        .systemLibrary(name: "CCmuxTerminal", path: "Sources/CCmuxTerminal"),
        .executableTarget(
            name: "NativeMuxDemo",
            dependencies: ["CCmuxTerminal"],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags(["-L../../../target/debug", "-lcmux_terminal_client"]),
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(name: "NativeMuxDemoTests", dependencies: ["NativeMuxDemo"]),
    ]
)
