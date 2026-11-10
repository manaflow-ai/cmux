import CmuxNextDesign

/// The suites that measure the pill look (an even inset from the card's edge, the sidebar's edge line,
/// a gap below the pill) pin the flush corner off: it is the default above compact density
/// (`CornerFlushTests`), where the selected tab runs into the card instead. `nil` resets it.
@MainActor enum CornerFlushTestPin {
    static func pin(_ value: CornerFlush?) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register([CornerFlush.tunable.descriptor])
        TunableStore.shared.set(CornerFlush.tunable.key, value?.tunableValue)
    }
}
