import AppKit
import CmuxNextDesign

/// Debug Settings `sidebar.bottomControls` (``SidebarBottomControlsVariant``): the bottom-left corner's
/// larger looks, placed over the footer band after it lays out. `.standard`, the compact density, Minimal
/// footers (`sidebar.noFade`) and a footer with no profile control keep the shipped footer untouched.
extension SidebarView {
    /// The look in effect now, nil for the shipped footer.
    var activeBottomControls: SidebarBottomControlsVariant? {
        let variant = SidebarTunables.bottomControls.value
        guard variant != .standard, SidebarDensityTokens.density != .compact, !design.sidebarSections.noFade,
              spacesPosition == .bottom, footerBand.bandFirstRow != nil, footerBand.profileControl != nil else { return nil }
        return variant
    }

    /// The footer height the look adds above the band's first line.
    var bottomControlsExtraHeight: CGFloat {
        guard let variant = activeBottomControls, let row = footerBand.bandFirstRow else { return 0 }
        return SidebarBottomControlsGeometry.extraHeight(variant, rowHeight: row.frame.height, gap: Metrics.space1)
    }

    func wireBottomControls() {
        bottomControls.avatarButton.onPress = { [weak self] in
            guard let self else { return }
            _ = self.footerBand.showProfileMenu(from: self.bottomControls.avatarButton)
        }
        bottomControls.accountRow.onPress = { [weak self] in
            guard let self else { return }
            _ = self.footerBand.showProfileMenu(from: self.bottomControls.accountRow)
        }
        bottomControls.searchField.onPress = { [weak self] in
            guard let self else { return }
            self.onSearch?(self.bottomControls.searchField)
        }
        bottomControls.searchField.setAccessibilityIdentifier("cmux.sidebar.search.field")
        bottomControls.avatarButton.setAccessibilityIdentifier("cmux.sidebar.profile.large")
        bottomControls.accountRow.setAccessibilityIdentifier("cmux.sidebar.profile.row")
        addSubview(bottomControls)
    }

    /// The anchor the profile menu opens from: the look's avatar or account row while one shows.
    var profileMenuAnchor: NSView? {
        if !bottomControls.avatarButton.isHidden { return bottomControls.avatarButton }
        if !bottomControls.accountRow.isHidden { return bottomControls.accountRow }
        return footerBand.profileControl?.view
    }

    /// Places the look's controls after `footerBand.placeSpaces`: it resizes Search, moves the spaces
    /// strip between the controls and clears the footer's own avatar tile under the larger one.
    func layoutBottomControls() {
        let tile = footerBand.profileControl?.view
        bottomControls.frame = bounds
        guard let variant = activeBottomControls, let row = footerBand.bandFirstRow else {
            bottomControls.apply(nil, avatar: nil)
            tile?.alphaValue = 1
            return
        }
        let geometry = SidebarBottomControlsGeometry.layout(
            variant, width: bounds.width, column: newButton.frame.midX, line: row.frame, upper: footer.frame,
            topButtonSide: SidebarStyle.toolbarButtonSize, scale: window?.backingScaleFactor ?? 2)
        bottomControls.apply(geometry, avatar: model.profileAvatar)
        // The shipped tile keeps its place in the region (its id, drag and menu paths) but draws nothing.
        tile?.alphaValue = 0
        if design.sidebarSections.showSearchButton {
            searchButton.isHidden = geometry.search == nil
            if let search = geometry.search { searchButton.frame = search }
        }
        if !profileBar.isHidden {
            if profileBar.superview !== self { addSubview(profileBar, positioned: .below, relativeTo: bottomControls) }
            profileBar.leadingInset = 0
            profileBar.frame = geometry.spaces
            profileBar.centerX = bounds.midX - geometry.spaces.minX
            profileBar.refresh()
        }
    }
}
