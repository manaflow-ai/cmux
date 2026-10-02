extension MobileMacConnectionRegistry {
    enum Entry {
        case control(SecondaryMacSubscription)
        case focused(MacConnection)
    }
}
