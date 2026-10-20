import CMUXMobileCore

struct PairedMacBackupFailableRoute: Decodable {
    let value: CmxAttachRoute?

    init(from decoder: any Decoder) {
        value = try? CmxAttachRoute(from: decoder)
    }
}
