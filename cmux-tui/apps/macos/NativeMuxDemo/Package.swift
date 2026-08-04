// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NativeMuxDemo",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "NativeMuxDemo", targets: ["NativeMuxDemo"])
  ],
  targets: [
    .systemLibrary(name: "GhosttyKit", path: "Sources/GhosttyKit"),
    .systemLibrary(name: "CCmuxTerminal", path: "Sources/CCmuxTerminal"),
    .executableTarget(
      name: "NativeMuxDemo",
      dependencies: ["CCmuxTerminal", "GhosttyKit"],
      linkerSettings: [
        .unsafeFlags([
          "-L../../../target/native-mux-demo/rust-build/debug", "-lcmux_terminal_client",
        ]),
        .unsafeFlags([
          "../../../../GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"
        ]),
        .linkedFramework("Carbon"),
        .linkedLibrary("c++"),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreText"),
        .linkedFramework("IOSurface"),
        .linkedFramework("Metal"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"),
        .linkedFramework("WebKit"),
      ]
    ),
    .testTarget(name: "NativeMuxDemoTests", dependencies: ["NativeMuxDemo"]),
  ]
)
