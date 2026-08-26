import AppKit
import CmuxSwiftRender
import QuartzCore
import SwiftUI

/// Prepares and mounts a custom sidebar for a deterministic smoke artifact.
///
/// Preparation evaluates or decodes the source off the main actor. Rendering
/// then mounts ``CustomSidebarContentView`` in an offscreen ``NSHostingView``;
/// that view is the same presentation path used by both the in-process app
/// surface and the remote render worker. A PNG is written only after AppKit
/// layout and display have produced visible pixels.
public struct CustomSidebarRenderDiagnostic: Sendable {
    /// Bounds bitmap allocation for a socket-triggered smoke render.
    public static let maximumDimension = 4096

    private let fileManagerProvider: @Sendable () -> FileManager

    /// Creates a renderer using the shared sidebar evaluator and presentation.
    ///
    /// - Parameter fileManagerProvider: Supplies the filesystem handle used
    ///   for source reads and artifact writes. The default uses the process's
    ///   standard file manager; tests can provide an isolated handle.
    public init(
        fileManagerProvider: @escaping @Sendable () -> FileManager = { .default }
    ) {
        self.fileManagerProvider = fileManagerProvider
    }

    /// Loads and evaluates one sidebar without mounting it.
    ///
    /// - Parameters:
    ///   - fileURL: The `.swift` or `.json` sidebar source to load.
    ///   - dataContext: Values exposed to interpreted Swift source; the
    ///     validator's representative context is used by default.
    /// - Returns: An immutable plan ready for ``render(plan:width:height:outputURL:)``.
    /// - Throws: ``CustomSidebarRenderDiagnosticError`` when the source is
    ///   missing, unreadable, unsupported, or does not evaluate.
    public func prepare(
        fileURL: URL,
        dataContext: [String: SwiftValue] = CustomSidebarValidator.defaultDataContext
    ) throws -> CustomSidebarRenderPlan {
        let fileManager = fileManagerProvider()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw CustomSidebarRenderDiagnosticError.fileMissing
        }

        switch fileURL.pathExtension.lowercased() {
        case "swift":
            let source: String
            do {
                source = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                throw CustomSidebarRenderDiagnosticError.readFailed(error.localizedDescription)
            }
            guard let node = SwiftViewInterpreter().evaluate(source, state: dataContext) else {
                throw CustomSidebarRenderDiagnosticError.noView
            }
            return CustomSidebarRenderPlan(
                fileURL: fileURL,
                kind: .swift,
                state: .swiftSource(source),
                swiftRender: node,
                hasRenderedSwift: true
            )

        case "json":
            let document: DSLDocument
            do {
                let data = try Data(contentsOf: fileURL)
                document = try JSONDecoder().decode(DSLDocument.self, from: data)
            } catch {
                throw CustomSidebarRenderDiagnosticError.readFailed(error.localizedDescription)
            }
            return CustomSidebarRenderPlan(
                fileURL: fileURL,
                kind: .json,
                state: .json(document),
                swiftRender: nil,
                hasRenderedSwift: false
            )

        default:
            throw CustomSidebarRenderDiagnosticError.unsupportedFile
        }
    }

    /// Mounts a prepared sidebar and writes a PNG artifact.
    ///
    /// - Parameters:
    ///   - plan: A plan returned by ``prepare(fileURL:dataContext:)``.
    ///   - width: Artifact width in pixels, from 1 through
    ///     ``maximumDimension``.
    ///   - height: Artifact height in pixels, from 1 through
    ///     ``maximumDimension``.
    ///   - outputURL: Destination path for the atomically written PNG.
    /// - Returns: Metadata describing the written artifact and visible pixels.
    /// - Throws: ``CustomSidebarRenderDiagnosticError`` when mounting, layout,
    ///   pixel generation, or writing fails.
    @MainActor
    public func render(
        plan: CustomSidebarRenderPlan,
        width: Int,
        height: Int,
        outputURL: URL
    ) throws -> CustomSidebarRenderArtifact {
        guard width > 0, height > 0,
              width <= Self.maximumDimension, height <= Self.maximumDimension else {
            throw CustomSidebarRenderDiagnosticError.invalidSize
        }

        let size = NSSize(width: width, height: height)
        let content = CustomSidebarContentView(
            state: plan.state,
            swiftRender: plan.swiftRender,
            hasRenderedSwift: plan.hasRenderedSwift,
            dispatch: .noop,
            contentInsets: .zero
        )
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .light)

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.setContentSize(size)

        guard let contentView = window.contentView else {
            throw CustomSidebarRenderDiagnosticError.mountFailed
        }
        contentView.frame = NSRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        hosting.displayIfNeeded()
        CATransaction.flush()

        let bounds = hosting.bounds
        guard !bounds.isEmpty else {
            throw CustomSidebarRenderDiagnosticError.mountFailed
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw CustomSidebarRenderDiagnosticError.bitmapFailed
        }
        bitmap.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CustomSidebarRenderDiagnosticError.bitmapFailed
        }

        let visiblePixelCount = visiblePixelCount(in: bitmap)
        guard visiblePixelCount > 0 else {
            throw CustomSidebarRenderDiagnosticError.blankOutput
        }

        do {
            let fileManager = fileManagerProvider()
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pngData.write(to: outputURL, options: .atomic)
        } catch {
            throw CustomSidebarRenderDiagnosticError.writeFailed(error.localizedDescription)
        }

        return CustomSidebarRenderArtifact(
            outputURL: outputURL,
            width: width,
            height: height,
            visiblePixelCount: visiblePixelCount,
            byteCount: pngData.count
        )
    }

    @MainActor
    private func visiblePixelCount(in bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    count += 1
                }
            }
        }
        return count
    }
}
