#if canImport(UIKit)
public import SwiftUI
import UIKit

/// The one browser chrome both phone browsers use: the streamed Mac/cmux-tui
/// browser and the native in-app `WKWebView` browser.
///
/// A single always-visible bottom glass bar in the thumb zone: back, forward,
/// an editable address field, reload (or stop while loading, when the
/// browser can stop), an optional keyboard toggle, and, where a browser can
/// switch between Streamed and On iPhone, a small mode menu. Hosts place it in a
/// bottom `safeAreaInset` so it reserves its height (never occluding page
/// content) and rides up with the keyboard.
///
/// The bar owns only presentation state (the address text being edited and
/// its focus); page state comes in as values and every action goes out
/// through a closure, so each browser keeps its own engine.
public struct MobileBrowserChromeBar: View {
    /// Page state the bar reflects.
    public struct Page: Equatable {
        /// The address shown while not editing, or `nil` before a page loads.
        public var url: String?
        public var canGoBack: Bool
        public var canGoForward: Bool
        public var isLoading: Bool
        /// Load progress in `0...1`, shown while ``isLoading``.
        public var progress: Double

        public init(url: String?, canGoBack: Bool, canGoForward: Bool, isLoading: Bool, progress: Double) {
            self.url = url
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            self.isLoading = isLoading
            self.progress = progress
        }
    }

    /// Navigation actions.
    public struct Actions {
        public var back: () -> Void
        public var forward: () -> Void
        public var reload: () -> Void
        /// Stops the load in flight. When set, reload becomes stop while loading.
        public var stop: (() -> Void)?
        /// Navigates to the submitted address text. Returns whether it was
        /// accepted (editing ends only then).
        public var submit: (String) -> Bool
        /// Reports address editing begin/end.
        public var editingChanged: (Bool) -> Void

        public init(
            back: @escaping () -> Void,
            forward: @escaping () -> Void,
            reload: @escaping () -> Void,
            stop: (() -> Void)? = nil,
            submit: @escaping (String) -> Bool,
            editingChanged: @escaping (Bool) -> Void = { _ in }
        ) {
            self.back = back
            self.forward = forward
            self.reload = reload
            self.stop = stop
            self.submit = submit
            self.editingChanged = editingChanged
        }
    }

    /// A keyboard toggle for pages that cannot raise the keyboard themselves
    /// (a streamed page is pixels, not text fields).
    public struct KeyboardToggle {
        /// Raises the keyboard for page input.
        public var show: () -> Void
        /// Called after the bar ends address editing, before it dismisses
        /// the keyboard.
        public var hide: () -> Void

        public init(show: @escaping () -> Void, hide: @escaping () -> Void) {
            self.show = show
            self.hide = hide
        }
    }

    /// Accessibility identifiers, derived from one prefix so each browser's
    /// UI tests keep their names (`<prefix>BackButton`, ...).
    public struct Identifiers {
        public var back: String
        public var forward: String
        public var address: String
        public var reload: String
        public var stop: String
        public var keyboard: String
        public var progress: String

        public init(prefix: String, address: String? = nil) {
            back = "\(prefix)BackButton"
            forward = "\(prefix)ForwardButton"
            self.address = address ?? "\(prefix)AddressField"
            reload = "\(prefix)ReloadButton"
            stop = "\(prefix)StopButton"
            keyboard = "\(prefix)KeyboardButton"
            progress = "\(prefix)Progress"
        }
    }

    private let page: Page
    private let actions: Actions
    private let keyboard: KeyboardToggle?
    private let modePicker: MobileBrowserModePicker?
    private let identifiers: Identifiers

    @State private var addressText: String
    @State private var isEditingAddress = false
    @FocusState private var addressFocused: Bool
    /// Real soft-keyboard visibility; the keyboard button binds to this rather
    /// than one responder's focus intent because the address field, a page
    /// input, or a dialog's text field can raise the keyboard.
    @State private var keyboardVisibility = MobileKeyboardVisibilityObserver()

    public init(
        page: Page,
        actions: Actions,
        keyboard: KeyboardToggle? = nil,
        modePicker: MobileBrowserModePicker? = nil,
        identifiers: Identifiers
    ) {
        self.page = page
        self.actions = actions
        self.keyboard = keyboard
        self.modePicker = modePicker
        self.identifiers = identifiers
        _addressText = State(initialValue: page.url ?? "")
    }

    public var body: some View {
        HStack(spacing: 10) {
            chromeButton(
                systemImage: "chevron.backward",
                label: L10n.string("mobile.browserStream.back", defaultValue: "Back"),
                identifier: identifiers.back,
                disabled: !page.canGoBack,
                action: actions.back
            )
            chromeButton(
                systemImage: "chevron.forward",
                label: L10n.string("mobile.browserStream.forward", defaultValue: "Forward"),
                identifier: identifiers.forward,
                disabled: !page.canGoForward,
                action: actions.forward
            )

            addressField

            if page.isLoading, let stop = actions.stop {
                chromeButton(
                    systemImage: "xmark",
                    label: L10n.string("mobile.browser.stop", defaultValue: "Stop"),
                    identifier: identifiers.stop,
                    action: stop
                )
            } else {
                chromeButton(
                    systemImage: "arrow.clockwise",
                    label: L10n.string("mobile.browserStream.reload", defaultValue: "Reload"),
                    identifier: identifiers.reload,
                    action: actions.reload
                )
            }
            if let keyboard {
                chromeButton(
                    systemImage: keyboardVisibility.isVisible ? "keyboard.chevron.compact.down" : "keyboard",
                    label: keyboardVisibility.isVisible
                        ? L10n.string("mobile.browserStream.hideKeyboard", defaultValue: "Hide Keyboard")
                        : L10n.string("mobile.browserStream.keyboard", defaultValue: "Show Keyboard"),
                    identifier: identifiers.keyboard
                ) {
                    if keyboardVisibility.isVisible {
                        // Hide means hide, whichever responder raised the keyboard.
                        addressFocused = false
                        keyboard.hide()
                        UIApplication.shared.dismissMobileKeyboard()
                    } else {
                        keyboard.show()
                    }
                }
            }
            if let modePicker {
                MobileBrowserModeMenu(picker: modePicker)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .mobileGlassPill()
        .overlay(alignment: .bottom) { pillProgress }
        .clipShape(Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .onChange(of: page.url) { _, url in
            if !addressFocused { addressText = url ?? "" }
        }
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            if !isEditingAddress {
                Image(systemName: isSecure ? "lock.fill" : "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextField(
                L10n.string("mobile.browserStream.addressPlaceholder", defaultValue: "Search or enter address"),
                text: $addressText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.webSearch)
            .submitLabel(.go)
            .multilineTextAlignment(isEditingAddress ? .leading : .center)
            .focused($addressFocused)
            .onSubmit { submitAddress() }
            .font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .onChange(of: addressFocused) { _, focused in
            isEditingAddress = focused
            actions.editingChanged(focused)
            // Show the full URL for editing, collapse back to the page on blur.
            if focused {
                addressText = page.url ?? addressText
            } else {
                addressText = page.url ?? ""
            }
        }
        .accessibilityIdentifier(identifiers.address)
    }

    @ViewBuilder
    private var pillProgress: some View {
        if page.isLoading {
            ProgressView(value: page.progress)
                .progressViewStyle(.linear)
                .frame(height: 2)
                .padding(.horizontal, 18)
                .accessibilityLabel(L10n.string("mobile.browserStream.loading", defaultValue: "Loading"))
                .accessibilityIdentifier(identifiers.progress)
        }
    }

    private var isSecure: Bool {
        page.url?.hasPrefix("https://") == true
    }

    private func chromeButton(
        systemImage: String,
        label: String,
        identifier: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: systemImage).frame(width: 24, height: 24) }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private func submitAddress() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if actions.submit(trimmed) {
            addressFocused = false
        }
    }
}
#endif
