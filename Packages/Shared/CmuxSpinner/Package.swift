// swift-tools-version: 6.0

import PackageDescription

// The one spinner of the cmux surfaces outside CmuxNextDesign (the iPhone app, the shared Home and
// Screen packages): a thin arc that turns clockwise once per spinner period, the period every
// cmux spinner turns at (schemas/motion-scale/motion-scale.json `spinner`; Leo 2026-11-07: "Let's
// have all our spinners go at that speed."). The macOS app's own spinners draw the same arc in
// CmuxNextDesign's StatusIndicatorLayer on the same period.
let package = Package(
    name: "CmuxSpinner",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxSpinner", targets: ["CmuxSpinner"]),
    ],
    targets: [
        .target(
            name: "CmuxSpinner",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxSpinnerTests",
            dependencies: ["CmuxSpinner"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
