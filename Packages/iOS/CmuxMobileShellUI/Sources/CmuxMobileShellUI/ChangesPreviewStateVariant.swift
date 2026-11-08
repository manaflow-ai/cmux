#if os(iOS) && DEBUG
enum ChangesPreviewStateVariant: String, CaseIterable, Identifiable {
    case loading
    case error

    var id: String { rawValue }
}
#endif
