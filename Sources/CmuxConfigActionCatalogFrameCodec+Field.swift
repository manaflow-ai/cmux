import Foundation

extension CmuxConfigActionCatalogFrameCodec {
    struct Field {
        let status: CmuxConfigActionCatalogRawFileStatus
        let payload: Data
    }
}
