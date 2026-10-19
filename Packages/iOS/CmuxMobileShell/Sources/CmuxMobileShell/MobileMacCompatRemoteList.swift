/// The wire shape returned by `GET /api/mobile-mac-compat`.
struct MobileMacCompatRemoteList: Decodable {
    let entries: [MobileMacCompatRemoteEntry]
}
