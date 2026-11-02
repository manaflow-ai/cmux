extension LayoutModel {
    /// Drops `transaction`'s live values for `keys`, a modifier drag that stops setting them
    /// (plans/cmux-next/resize-modifiers.md): the daemon's values show again, none is sent on release.
    public func restoreGestureValues(_ keys: Set<DividerDragValueKey>, transaction: LayoutTransactionID) {
        guard !keys.isEmpty else { return }
        let count = splitOverrides.count + widthOverrides.count
        splitOverrides = splitOverrides.filter { !keys.contains(.split($0.key)) || $0.value.transaction != transaction }
        widthOverrides = widthOverrides.filter { !keys.contains(.column($0.key)) || $0.value.transaction != transaction }
        if splitOverrides.count + widthOverrides.count != count { showOverlaid() }
    }
}
