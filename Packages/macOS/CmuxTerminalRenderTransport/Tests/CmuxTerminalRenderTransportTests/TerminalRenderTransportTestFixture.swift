import CoreFoundation
import Foundation
import IOSurface
@testable import CmuxTerminalRenderProtocol
@testable import CmuxTerminalRenderTransport

struct TerminalRenderTransportTestFixture {
    let daemonInstanceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let terminalID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let presentationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let completionFenceEventID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    func makeFence(
        rendererEpoch: UInt64 = 7,
        presentationGeneration: UInt64 = 13,
        width: UInt32 = 32,
        height: UInt32 = 24,
        pixelFormat: TerminalRenderPixelFormat = .bgra8Unorm,
        producerCompleted: Bool = false
    ) throws -> TerminalRenderPresentationFence {
        try TerminalRenderPresentationFence(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: rendererEpoch,
            terminalID: terminalID,
            terminalEpoch: 11,
            minimumTerminalSequence: 90,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            colorSpace: .displayP3,
            completionRequirement: producerCompleted
                ? .producerCompleted
                : .sharedEvent(eventID: completionFenceEventID, minimumValue: 10)
        )
    }

    func makeMetadata(
        rendererEpoch: UInt64 = 7,
        terminalSequence: UInt64 = 100,
        presentationGeneration: UInt64 = 13,
        frameSequence: UInt64 = 17,
        width: UInt32 = 32,
        height: UInt32 = 24,
        pixelFormat: TerminalRenderPixelFormat = .bgra8Unorm,
        completionFenceValue: UInt64 = 19,
        producerCompleted: Bool = false,
        damageBounds: TerminalRenderDamageBounds? = nil
    ) throws -> TerminalRenderFrameMetadata {
        try TerminalRenderFrameMetadata(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: rendererEpoch,
            terminalID: terminalID,
            terminalEpoch: 11,
            terminalSequence: terminalSequence,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration,
            frameSequence: frameSequence,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            colorSpace: .displayP3,
            completionFence: producerCompleted
                ? .producerCompleted
                : .sharedEvent(
                    eventID: completionFenceEventID,
                    value: completionFenceValue
                ),
            damageBounds: damageBounds
        )
    }

    func makeSurface(
        width: Int = 32,
        height: Int = 24,
        pixelFormat: TerminalRenderPixelFormat = .bgra8Unorm,
        bytesPerElementOverride: Int? = nil
    ) -> TerminalRenderSurfaceHandle {
        let bytesPerElement = bytesPerElementOverride
            ?? Int(pixelFormat.bytesPerPixel)
        let bytesPerRow = width * bytesPerElement
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: bytesPerElement,
            kIOSurfaceBytesPerRow: bytesPerRow,
            kIOSurfaceAllocSize: bytesPerRow * height,
            kIOSurfacePixelFormat: pixelFormat.rawValue,
        ]
        return TerminalRenderSurfaceHandle(
            surface: IOSurfaceCreate(properties as CFDictionary)!
        )
    }

    func executableCandidates(named name: String) -> [URL] {
        let fileManager = FileManager.default
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildDirectory = packageRoot.appendingPathComponent(".build")
        var candidates = [
            buildDirectory.appendingPathComponent("debug").appendingPathComponent(name)
        ]
        if let architectureDirectories = try? fileManager.contentsOfDirectory(
            at: buildDirectory,
            includingPropertiesForKeys: nil
        ) {
            candidates.append(contentsOf: architectureDirectories.map {
                $0.appendingPathComponent("debug").appendingPathComponent(name)
            })
        }
        return candidates.filter { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
