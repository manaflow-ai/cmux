/// The forms of one Settings page that hold typed values not saved yet (a custom density being
/// edited, a relay's fields), as the page reports them (`cmux.settings.editing`). While any does,
/// the page's tab keeps its view (``SettingsWindowService/keepReasons(for:)``): a page built again
/// would lose them (Chrome's kUserEdits, components/performance_manager/public/decorators/
/// page_live_state_decorator.h `IsHavingUserEdits` and cannot_discard_reason.h).
@MainActor
final class SettingsPageEdits {
    /// The page's unsaved forms, by the page's own form names.
    private(set) var forms: Set<String> = []

    /// Whether any form holds unsaved values.
    var hasUnsaved: Bool { !forms.isEmpty }

    /// The page says form `form` holds unsaved values (`unsaved`), or no longer does.
    func set(_ form: String, unsaved: Bool) {
        if unsaved { forms.insert(form) } else { forms.remove(form) }
    }
}
