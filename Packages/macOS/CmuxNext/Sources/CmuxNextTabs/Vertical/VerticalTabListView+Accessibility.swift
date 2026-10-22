import AppKit

// VoiceOver and automation: one element per tab row, as the strip's cells give
// (`TabAccessibilityElement`), pressable to select and with Close Tab and Mute Tab actions.
extension VerticalTabListView {
    public override func accessibilityChildren() -> [Any]? {
        listLayout.rows.compactMap { Self.tabID($0.kind).flatMap { accessibilityRows[$0] } }
    }

    /// Makes, updates and drops the row elements after a layout.
    func updateAccessibilityRows() {
        var kept: [TabID: TabAccessibilityElement] = [:]
        for row in listLayout.rows {
            guard let id = Self.tabID(row.kind), let item = model.tab(id) else { continue }
            let element = accessibilityRows[id] ?? makeAccessibilityRow(id)
            var parts = [item.title.isEmpty ? Strings.untitled : item.title]
            if item.isPinned { parts.append(Strings.axPinned) }
            if item.isDormant { parts.append(Strings.axHibernated) }
            if let audio = item.audio { parts.append(audio == .muted ? Strings.axMuted : Strings.axPlayingAudio) }
            if item.isUnread { parts.append(Strings.axUnread) }
            element.setAccessibilityLabel(parts.joined(separator: ", "))
            element.setAccessibilityValue(id == model.selectedID ? 1 : 0)
            if item.isClosable {
                element.onClose = { [weak self] in self?.model.send(.close(id, source: .accessibility)) }
            } else {
                element.onClose = nil
            }
            let mute: @MainActor () -> Void = { [weak self] in self?.model.send(.toggleAudioMute(id)) }
            element.audioAction = item.audio.map { audio in (name: audio == .muted ? Strings.unmuteTab : Strings.muteTab, run: mute) }
            // Unflipped parent space; a scrolled-away row keeps its place outside the bounds.
            let frame = viewRect(row.frame)
            element.setAccessibilityFrameInParentSpace(CGRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height))
            kept[id] = element
        }
        accessibilityRows = kept
    }

    private func makeAccessibilityRow(_ id: TabID) -> TabAccessibilityElement {
        let element = TabAccessibilityElement()
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
