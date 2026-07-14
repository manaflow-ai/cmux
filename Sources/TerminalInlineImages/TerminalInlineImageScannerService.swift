import CMUXMobileCore
import Foundation

/// Decodes and scans render-grid snapshots away from the main actor.
struct TerminalInlineImageScannerService: Sendable {
    private let scanner = TerminalTranscriptImagePathScanner()

    #if compiler(>=6.2)
    @concurrent
    #endif
    func scan(_ request: TerminalInlineImageScanRequest) async -> [DetectedImagePath]? {
        guard !Task.isCancelled,
              let frame = try? JSONDecoder().decode(
                  MobileTerminalRenderGridFrame.self,
                  from: request.gridJSON
              ),
              frame.activeScreen == .primary,
              !Task.isCancelled else {
            return nil
        }
        return scanner.scan(rows: frame.plainRows(), context: request.context)
    }
}
