#if os(iOS)
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct MobileFeedbackPickedPhotoFile: Sendable, Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let fileManager = FileManager()
            let extensionPart = received.file.pathExtension
            let fileName = extensionPart.isEmpty
                ? UUID().uuidString
                : "\(UUID().uuidString).\(extensionPart)"
            let copyURL = fileManager.temporaryDirectory.appendingPathComponent(fileName)
            try fileManager.copyItem(at: received.file, to: copyURL)
            return MobileFeedbackPickedPhotoFile(url: copyURL)
        }
    }

    func removeTemporaryFile() {
        try? FileManager().removeItem(at: url)
    }
}
#endif
