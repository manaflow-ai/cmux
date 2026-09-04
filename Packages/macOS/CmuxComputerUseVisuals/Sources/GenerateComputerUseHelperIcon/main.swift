import AppKit
import CoreGraphics
import Foundation
import ImageIO

import CmuxComputerUseVisuals

private struct GeneratorArguments {
    let outputURL: URL
    let svgOutputURL: URL?

    /// Parses the output paths accepted by the legacy generator entry point.
    init() throws {
        var outputPath: String?
        var svgPath: String?
        var arguments = CommandLine.arguments.dropFirst()
        while let argument = arguments.popFirst() {
            switch argument {
            case "--output":
                outputPath = try Self.requiredPath(
                    after: argument,
                    from: &arguments
                )
            case "--svg-output":
                svgPath = try Self.requiredPath(
                    after: argument,
                    from: &arguments
                )
            case "--help", "-h":
                print("Usage: generate-computer-use-helper-icon --output PATH [--svg-output PATH]")
                exit(0)
            default:
                throw NSError(
                    domain: "CmuxComputerUseVisualsGenerator",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "unknown argument: \(argument)"]
                )
            }
        }
        guard let outputPath else {
            throw NSError(
                domain: "CmuxComputerUseVisualsGenerator",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "--output is required"]
            )
        }
        outputURL = URL(fileURLWithPath: outputPath)
        svgOutputURL = svgPath.map { URL(fileURLWithPath: $0) }
    }

    /// Reads one non-empty path argument and produces a useful CLI error when
    /// an option is accidentally left without its value.
    private static func requiredPath(
        after option: String,
        from arguments: inout ArraySlice<String>
    ) throws -> String {
        guard let path = arguments.popFirst(), !path.isEmpty else {
            throw NSError(
                domain: "CmuxComputerUseVisualsGenerator",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: option + " requires a non-empty path"
                ]
            )
        }
        return path
    }
}

private struct ComputerUseHelperIconGenerator {
    private let artwork = ComputerUseCursorArtwork()
    private let tokens = ComputerUseOnboardingVisualTokens.reference
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Returns the fixed dark plate gradient used by the shipped ICNS asset.
    private func plateColors() -> [CGColor] {
        [
            CGColor(gray: 0x31 / 255.0, alpha: 1.0),
            CGColor(gray: 0x14 / 255.0, alpha: 1.0),
        ]
    }

    /// Returns the fixed inner-rim highlight gradient used by the asset.
    private func rimColors() -> [CGColor] {
        [
            CGColor(gray: 1.0, alpha: 0.34),
            CGColor(gray: 1.0, alpha: 0.05),
        ]
    }

    /// Renders the canonical helper icon at its source-canvas resolution.
    func render() -> CGImage? {
        let canvas = CGRect(origin: .zero, size: tokens.helperIconCanvasSize)
        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Flip once so the shared path retains the up-left direction used by
        // the live pointer renderer.
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)

        let plate = CGPath(
            roundedRect: canvas,
            cornerWidth: tokens.helperIconCornerRadius,
            cornerHeight: tokens.helperIconCornerRadius,
            transform: nil
        )
        drawGradient(
            in: context,
            clippedTo: plate,
            colors: plateColors(),
            locations: [0.0, 1.0]
        )

        let rim = plate.copy(
            strokingWithWidth: tokens.helperIconRimWidth * 2,
            lineCap: .butt,
            lineJoin: .miter,
            miterLimit: 10
        )
        context.saveGState()
        context.addPath(plate)
        context.clip()
        context.addPath(rim)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: rimColors() as CFArray,
            locations: [0.0, 1.0]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: canvas.midX, y: 0),
                end: CGPoint(x: canvas.midX, y: canvas.height),
                options: []
            )
        }
        context.restoreGState()

        context.translateBy(
            x: tokens.helperIconCursorTranslation.x,
            y: tokens.helperIconCursorTranslation.y
        )
        artwork.draw(in: context, scale: tokens.helperIconCursorScale)
        return context.makeImage()
    }

    /// Draws a vertical gradient clipped to one icon shape.
    private func drawGradient(
        in context: CGContext,
        clippedTo path: CGPath,
        colors: [CGColor],
        locations: [CGFloat]
    ) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: locations
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: tokens.helperIconCanvasSize.width / 2, y: 0),
                end: CGPoint(
                    x: tokens.helperIconCanvasSize.width / 2,
                    y: tokens.helperIconCanvasSize.height
                ),
                options: []
            )
        }
        context.restoreGState()
    }

    /// Writes an SVG representation using the same cursor translation tokens.
    func writeSVG(to url: URL) throws {
        let translation = tokens.helperIconCursorTranslation
        let scale = tokens.helperIconCursorScale
        let size = tokens.helperIconCanvasSize.width
        let radius = tokens.helperIconCornerRadius
        let svg = """
        <svg width="\(decimal(size))" height="\(decimal(tokens.helperIconCanvasSize.height))" viewBox="0 0 \(decimal(size)) \(decimal(tokens.helperIconCanvasSize.height))" xmlns="http://www.w3.org/2000/svg">
          <!-- ComputerUseCursorArtwork's canonical Sky path, gradient, and
               direction on a rounded translucent plate. -->
          <defs>
            <linearGradient id="cur" x1="0.68" y1="0.68" x2="11" y2="11" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="#12c7f5"/>
              <stop offset="0.5" stop-color="#2d8cff"/>
              <stop offset="1" stop-color="#6c5cff"/>
            </linearGradient>
          </defs>
          <rect width="\(decimal(size))" height="\(decimal(tokens.helperIconCanvasSize.height))" rx="\(decimal(radius))" fill="#FFFFFF" fill-opacity="0.14"/>
          <!-- Center the canonical kite's tight visible bounds, not its ink centroid. -->
          <g transform="translate(\(decimal(translation.x)) \(decimal(translation.y))) scale(\(decimal(scale)))">
            <path
              d="\(ComputerUseCursorArtwork.svgPathData)"
              fill="url(#cur)"/>
          </g>
        </svg>
        """ + "\n"
        guard let data = svg.data(using: .utf8) else {
            throw NSError(domain: "CmuxComputerUseVisualsGenerator", code: 9)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Encodes one rendered master image into all ICNS scale slots.
    func writeICNS(master: CGImage, to url: URL) throws {
        let iconsetURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "ComputerUseHelperIcon-\(ProcessInfo.processInfo.processIdentifier).iconset",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: iconsetURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: iconsetURL) }

        for side in [16, 32, 128, 256, 512] {
            try writePNG(master, side: side, name: "icon_\(side)x\(side).png", in: iconsetURL)
            try writePNG(master, side: side * 2, name: "icon_\(side)x\(side)@2x.png", in: iconsetURL)
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", url.path]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else {
            throw NSError(
                domain: "CmuxComputerUseVisualsGenerator",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
            )
        }
    }

    /// Resamples the master image into one iconset PNG slot.
    private func writePNG(
        _ image: CGImage,
        side: Int,
        name: String,
        in iconsetURL: URL
    ) throws {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "CmuxComputerUseVisualsGenerator", code: 4)
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else {
            throw NSError(domain: "CmuxComputerUseVisualsGenerator", code: 5)
        }
        let url = iconsetURL.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "CmuxComputerUseVisualsGenerator", code: 6)
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "CmuxComputerUseVisualsGenerator", code: 7)
        }
    }

    /// Formats geometry values with a stable locale and no redundant zeros.
    private func decimal(_ value: CGFloat) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
            .trimmingTrailingZeros
    }
}

private extension String {
    /// Removes a trailing fractional zero run from generated SVG numbers.
    var trimmingTrailingZeros: String {
        guard contains(".") else { return self }
        return trimmingTrailingCharacters("0").trimmingTrailingCharacters(".")
    }

    /// Removes repeated instances of one character from the end of a string.
    func trimmingTrailingCharacters(_ character: Character) -> String {
        var value = self
        while value.last == character {
            value.removeLast()
        }
        return value
    }
}

do {
    let arguments = try GeneratorArguments()
    let generator = ComputerUseHelperIconGenerator()
    guard let master = generator.render() else {
        throw NSError(
            domain: "CmuxComputerUseVisualsGenerator",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "failed to render icon"]
        )
    }
    try generator.writeICNS(master: master, to: arguments.outputURL)
    if let svgOutputURL = arguments.svgOutputURL {
        try generator.writeSVG(to: svgOutputURL)
    }
    guard FileManager.default.fileExists(atPath: arguments.outputURL.path) else {
        throw NSError(
            domain: "CmuxComputerUseVisualsGenerator",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "icon output was not created"]
        )
    }
    if let svgOutputURL = arguments.svgOutputURL {
        guard FileManager.default.fileExists(atPath: svgOutputURL.path) else {
            throw NSError(
                domain: "CmuxComputerUseVisualsGenerator",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "SVG output was not created"]
            )
        }
    }
    print(arguments.outputURL.path)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
