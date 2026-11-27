#if os(iOS)
import SwiftUI
import VisionKit

/// VisionKit's live scanner, QR codes only; reports the first pairing link
/// (`cmux-vnc://…`). Check `PairingScanner.isSupported` before showing it.
public struct PairingScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    public init(found: @escaping (String) -> Void) {
        self.found = found
    }

    /// Whether this device can scan (a camera and VisionKit support).
    @MainActor public static var isSupported: Bool { DataScannerViewController.isSupported }

    public func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    public func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    public final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }

        public func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                if let value = code.payloadStringValue, value.hasPrefix("cmux-vnc://") {
                    found(value)
                    return
                }
            }
        }
    }
}
#endif
