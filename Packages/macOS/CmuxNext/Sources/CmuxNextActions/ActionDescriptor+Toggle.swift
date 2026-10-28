public nonisolated extension ActionDescriptor {
    /// This descriptor as a toggle: its title becomes `titles.whenOff` and both titles join
    /// its keywords, so a search for either side finds it (see ``ActionToggleTitles``).
    func toggling(_ titles: ActionToggleTitles) -> ActionDescriptor {
        var copy = self
        copy.toggleTitles = titles
        copy.title = titles.whenOff
        for title in [titles.whenOff, titles.whenOn] where !copy.keywords.contains(title) {
            copy.keywords.append(title)
        }
        return copy
    }

    /// This descriptor as a toggle with the two titles (see ``ActionToggleTitles``).
    func toggling(whenOff: String, whenOn: String, symbolWhenOff: String? = nil, symbolWhenOn: String? = nil) -> ActionDescriptor {
        toggling(ActionToggleTitles(whenOff: whenOff, whenOn: whenOn, symbolWhenOff: symbolWhenOff, symbolWhenOn: symbolWhenOn))
    }

    /// This descriptor as a toggle whose catalog title is the off title (Pin Workspace) and
    /// `whenOn` the title while on (Unpin Workspace); see ``ActionToggleTitles``.
    func toggling(whenOn: String, symbolWhenOff: String? = nil, symbolWhenOn: String? = nil) -> ActionDescriptor {
        toggling(ActionToggleTitles(whenOff: title, whenOn: whenOn, symbolWhenOff: symbolWhenOff, symbolWhenOn: symbolWhenOn))
    }
}
