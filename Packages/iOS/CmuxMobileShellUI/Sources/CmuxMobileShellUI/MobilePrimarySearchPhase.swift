#if os(iOS)
enum MobilePrimarySearchPhase: Equatable {
    case inactive
    case active(MobilePrimarySearchScope)
    case deactivating(MobilePrimarySearchScope)
}
#endif
