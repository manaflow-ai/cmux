import AppKit

// VoiceOver and automation: one element per tab row, as the strip's cells give
// (`TabAccessibilityElement`), pressable to select and with Close Tab and Mute Tab actions.
// Made when an accessibility client asks for them, not on every layout or scroll: each reads its
// frame from its row when asked (`frameInParent`), and a tab change updates its own element.
extension VerticalTabListView {
    public override func accessibilityChildren() -> [Any]? {
        if accessibilityRowsAreStale { updateAccessibilityRows() }
        return listLayout.rows.compactMap { Self.tabID($0.kind).flatMap { accessibilityRows[$0] } }
    }

    /// Makes, updates and drops the row elements after a layout.
    func updateAccessibilityRows() {
        accessibilityRowsAreStale = false
        var kept: [TabID: TabAccessibilityElement] = [:]
        for row in listLayout.rows {
            guard let id = Self.tabID(row.kind), let item = listLayout.item(row) else { continue }
            let element = accessibilityRows[id] ?? makeAccessibilityRow(id)
            configureAccessibilityRow(element, item)
            kept[id] = element
        }
        accessibilityRows = kept
    }

    /// `element` says what tab `item` is now.
    func configureAccessibilityRow(_ element: TabAccessibilityElement, _ item: TabItem) {
        let id = item.id
        var parts = [item.title.isEmpty ? Strings.untitled : item.title]
        if item.isPinned { parts.append(Strings.axPinned) }
        if item.isDormant { parts.append(Strings.axHibernated) }
        if let audio = item.audio { parts.append(audio == .muted ? Strings.axMuted : Strings.axPlayingAudio) }
        if item.isUnread { parts.append(Strings.axUnread) }
        element.setAccessibilityLabel(parts.joined(separator: ", "))
        element.setAccessibilityValue(id == model.selectedID ? 1 : 0)
        if item.isClosable {
            element.onClose = { @MainActor @Sendable [weak self] in
                guard let self else { return }
                self.model.send(.close(id, source: .accessibility))
            }
        } else {
            element.onClose = nil
        }
        let mute: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.model.send(.toggleAudioMute(id))
        }
        if let audio = item.audio {
            element.badgeActions = [(name: audio == .muted ? Strings.unmuteTab : Strings.muteTab, run: mute)]
        } else {
            element.badgeActions = []
        }
    }

    /// Tab `id`'s row in the list's unflipped space, where it shows now (a scrolled-away row keeps its place outside
    /// the bounds).
    func accessibilityFrame(ofTab id: TabID) -> CGRect {
        guard let content = listLayout.frame(of: id) else { return .zero }
        let frame = viewRect(content)
        return CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    private func makeAccessibilityRow(_ id: TabID) -> TabAccessibilityElement {
        let element = TabAccessibilityElement(frameInParent: { [weak self] in self?.accessibilityFrame(ofTab: id) ?? .zero })
        element.setAccessibilityParent(self)
        element.setAccessibilityIdentifier("cmux.tabs.vertical.\(id.rawValue)")
        element.closeButton.setAccessibilityLabel(Strings.axClose)
        element.onPress = { [weak self] in
            guard let self, let next = self.model.click(id, .plain), next != self.model.selectedID else { return }
            self.model.send(.select(next))
        }
        return element
    }
}
