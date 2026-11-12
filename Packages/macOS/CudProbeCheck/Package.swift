// swift-tools-version:5.9
// Scratch package: compile-checks scripts/measure/macos-cu-density/*.m on the Linux pool. Not for merge.
import PackageDescription
let objc: [CSetting] = [.unsafeFlags(["-fobjc-arc", "-Wno-deprecated-declarations"])]
let package = Package(
  name: "CudProbeCheck",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "cud", cSettings: objc, linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("CoreGraphics")]),
    .executableTarget(name: "cudvz", cSettings: objc, linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("Virtualization")]),
  ]
)
