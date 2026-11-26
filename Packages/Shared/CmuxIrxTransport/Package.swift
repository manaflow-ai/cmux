// swift-tools-version: 6.0

import Foundation
import PackageDescription

let package = Package(
    name: "CmuxIrxTransport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxIrxTransport",
            targets: ["CmuxIrxTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxEgress"),
        .package(path: "../CMUXMobileCore"),
        // Grant claims/verifier and terminal-envelope codecs are consumed as
        // stable data contracts; none of the legacy runtime machinery is used.
        .package(path: "../CmuxIrohTransport"),
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            exact: "1.2.0-cmux.1.ios17"
        ),
    ],
    targets: [
        .target(
            name: "CmuxIrxTransport",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CMUXMobileCore",
                "CmuxIrohTransport",
                .product(name: "CmuxEgress", package: "CmuxEgress"),
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "CmuxIrxTransportTests",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CMUXMobileCore",
                "CmuxIrohTransport",
                "CmuxIrxTransport",
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            resources: [
                .copy("V2/Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

#if os(Linux)
// The Linux package jobs (swift-linux-packages.yml) set CMUX_SWIFTPM_TARGET_LINUX; a build for an Apple
// platform, or for one on a Linux host (the fleet), keeps the manifest above. iroh-ffi's IrohLib is an
// Apple xcframework, so this shape drops it: the files over the native endpoint and connection
// (`#if canImport(IrohLib)`) compile out, and the control plane, V2 wire, judges, caches and tunnel
// policy build and test alone. CryptoKit is Apple-only; swift-crypto (`import Crypto`) gives the same API.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    package.dependencies.removeAll { dependency in
        if case .sourceControl(_, let location, _) = dependency.kind { return location.contains("iroh-ffi") }
        return false
    }
    package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"))
    for target in package.targets {
        target.dependencies.removeAll { dependency in
            if case .productItem(let name, _, _, _) = dependency { return name == "IrohLib" }
            return false
        }
        target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
        target.linkerSettings = nil
    }
}
#endif
