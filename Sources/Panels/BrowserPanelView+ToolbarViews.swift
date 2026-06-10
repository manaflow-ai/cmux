import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Address Bar & Toolbar Views
extension BrowserPanelView {
    var addressBar: some View {
        HStack(spacing: 8) {
            addressBarButtonBar

            omnibarField
                .accessibilityIdentifier("BrowserOmnibarPill")
                .accessibilityLabel("Browser omnibar")

            HStack(spacing: browserToolbarAccessorySpacing) {
                if shouldShowToolbarImportHintChip {
                    browserImportHintToolbarChip
                }
                browserFocusModeButtonWithShortcutHint
                screenshotPageButton
                reactGrabButton
                browserProfileButton
                browserThemeModeButton
                developerToolsButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, addressBarVerticalPadding)
        .background(browserChromeBackground)
        .background(
            WindowAccessor { window in
                focusModeShortcutHintMonitor.setHostWindow(window)
            }
        )
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: BrowserAddressBarHeightPreferenceKey.self,
                        value: geo.size.height
                    )
            }
        }
        // Keep the omnibar stack above WKWebView so the suggestions popup is visible.
        .zIndex(1)
        .environment(\.colorScheme, browserChromeColorScheme)
    }

    private var addressBarButtonBar: some View {
        return HStack(spacing: 0) {
            Button(action: {
                #if DEBUG
                cmuxDebugLog("browser.back panel=\(panel.id.uuidString.prefix(5))")
                #endif
                panel.goBack()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: chromeMetrics.navigationIconFontSize, weight: .medium))
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!panel.canGoBack)
            .opacity(panel.canGoBack ? 1.0 : 0.4)
            .safeHelp(String(localized: "browser.goBack", defaultValue: "Go Back"))

            Button(action: {
                #if DEBUG
                cmuxDebugLog("browser.forward panel=\(panel.id.uuidString.prefix(5))")
                #endif
                panel.goForward()
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: chromeMetrics.navigationIconFontSize, weight: .medium))
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .disabled(!panel.canGoForward)
            .opacity(panel.canGoForward ? 1.0 : 0.4)
            .safeHelp(String(localized: "browser.goForward", defaultValue: "Go Forward"))

            Button(action: handleReloadOrStopButtonAction) {
                Image(systemName: panel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: chromeMetrics.navigationIconFontSize, weight: .medium))
                    .frame(width: addressBarButtonHitSize, height: addressBarButtonHitSize, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .safeHelp(panel.isLoading ? String(localized: "browser.stop", defaultValue: "Stop") : String(localized: "browser.reload", defaultValue: "Reload"))

            if panel.isDownloading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "browser.downloading", defaultValue: "Downloading..."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                .safeHelp(String(localized: "browser.downloadInProgress", defaultValue: "Download in progress"))
            }
        }
    }

    private var screenshotPageButton: some View {
        Button(action: handleScreenshotPageButtonAction) {
            Image(systemName: screenshotPageCopied ? "checkmark" : "camera")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(screenshotPageButtonColor)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .disabled(!panel.shouldRenderWebView || screenshotPageCaptureInProgress)
        .opacity(panel.shouldRenderWebView ? 1.0 : 0.4)
        .safeHelp(
            screenshotPageCopied
                ? String(localized: "browser.screenshotPage.copied.help", defaultValue: "Screenshot copied to clipboard")
                : String(localized: "browser.screenshotPage.copy.help", defaultValue: "Screenshot Page to Clipboard")
        )
        .accessibilityIdentifier("BrowserScreenshotPageButton")
        .overlay(alignment: .top) {
            if screenshotPageCopied {
                Label(String(localized: "browser.screenshotPage.copied", defaultValue: "Copied"), systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .fixedSize()
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: screenshotPageCopied)
    }

    private var browserFocusModeButtonWithShortcutHint: some View {
        ZStack(alignment: .top) {
            browserFocusModeButton
            if shouldShowBrowserFocusModeShortcutHint {
                ShortcutHintPill(text: browserFocusModeShortcutHint, fontSize: 9, emphasis: 1.05)
                    .offset(y: -22)
                    .shortcutHintTransition()
                    .accessibilityIdentifier("BrowserFocusModeShortcutHint")
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .shortcutHintVisibilityAnimation(value: shouldShowBrowserFocusModeShortcutHint)
    }

    private var browserFocusModeButton: some View {
        Button(action: handleBrowserFocusModeButtonAction) {
            HStack(spacing: 5) {
                Image(systemName: "keyboard")
                    .font(.system(size: devToolsButtonIconSize, weight: .medium))
                    .scaleEffect(panel.isBrowserFocusModeActive ? 1.08 : 1.0)
                    .animation(.spring(response: 0.18, dampingFraction: 0.82), value: panel.isBrowserFocusModeActive)
                if panel.isBrowserFocusModeActive {
                    Text(
                        panel.isBrowserFocusModeExitArmed
                            ? String(localized: "browser.focusMode.armed", defaultValue: "Esc again to exit")
                            : String(localized: "browser.focusMode.active", defaultValue: "Focus Mode")
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundStyle(panel.isBrowserFocusModeActive ? Color.orange : devToolsColorOption.color)
            .padding(.horizontal, panel.isBrowserFocusModeActive ? 7 : 0)
            .frame(
                minWidth: panel.isBrowserFocusModeActive ? 0 : addressBarButtonSize,
                minHeight: addressBarButtonSize,
                alignment: .center
            )
            .animation(.easeOut(duration: 0.14), value: panel.isBrowserFocusModeActive)
            .animation(.easeOut(duration: 0.12), value: panel.isBrowserFocusModeExitArmed)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(height: addressBarButtonSize, alignment: .center)
        .disabled(!panel.canToggleBrowserFocusMode)
        .opacity(panel.canToggleBrowserFocusMode ? 1.0 : 0.4)
        .safeHelp(browserFocusModeButtonHelp)
        .accessibilityIdentifier("BrowserFocusModeButton")
    }

    private var screenshotPageButtonColor: Color {
        if screenshotPageCopied {
            return .green
        }
        return panel.shouldRenderWebView ? devToolsColorOption.color : Color.secondary
    }

    private var reactGrabButton: some View {
        Button(action: {
            panel.clearReactGrabRoundTrip(reason: "toolbarButton.manualStart")
            Task { await panel.toggleOrInjectReactGrab() }
        }) {
            Image(systemName: "cursorarrow.click.2")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(panel.isReactGrabActive ? Color.accentColor : Color.secondary)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .safeHelp(String(localized: "browser.reactGrab", defaultValue: "Inject React Grab"))
        .accessibilityIdentifier("BrowserReactGrabButton")
    }

    private var developerToolsButton: some View {
        Button(action: {
            openDevTools()
        }) {
            Image(systemName: devToolsIconOption.rawValue)
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(devToolsColorOption.color)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .safeHelp(developerToolsButtonHelp)
        .accessibilityIdentifier("BrowserToggleDevToolsButton")
    }

    private var browserProfileButton: some View {
        Button(action: {
            isBrowserProfileMenuPresented.toggle()
        }) {
            Image(systemName: "person.crop.circle")
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(devToolsColorOption.color)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .popover(isPresented: $isBrowserProfileMenuPresented, arrowEdge: .bottom) {
            browserProfilePopover
        }
        .safeHelp(
            String(
                format: String(
                    localized: "browser.profile.buttonHelp",
                    defaultValue: "Browser Profile: %@"
                ),
                panel.profileDisplayName
            )
        )
        .accessibilityIdentifier("BrowserProfileButton")
    }

    private var browserThemeModeButton: some View {
        Button(action: {
            isBrowserThemeMenuPresented.toggle()
        }) {
            Image(systemName: browserThemeMode.iconName)
                .symbolRenderingMode(.monochrome)
                .cmuxFlatSymbolColorRendering()
                .font(.system(size: devToolsButtonIconSize, weight: .medium))
                .foregroundStyle(browserThemeModeIconColor)
                .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
        .popover(isPresented: $isBrowserThemeMenuPresented, arrowEdge: .bottom) {
            browserThemeModePopover
        }
        .safeHelp(
            String(
                format: String(
                    localized: "browser.theme.buttonHelp",
                    defaultValue: "Browser Theme: %@"
                ),
                browserThemeMode.displayName
            )
        )
        .accessibilityIdentifier("BrowserThemeModeButton")
    }

    private var browserImportHintToolbarChip: some View {
        Button(action: {
            isBrowserImportHintPopoverPresented.toggle()
        }) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 10, weight: .medium))
                Text(String(localized: "browser.import.hint.toolbar", defaultValue: "Import"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(devToolsColorOption.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .popover(isPresented: $isBrowserImportHintPopoverPresented, arrowEdge: .bottom) {
            browserImportHintPopover
        }
        .safeHelp(String(localized: "browser.import.hint.toolbar.help", defaultValue: "Import browser data"))
        .accessibilityIdentifier("BrowserImportHintToolbarChip")
    }

    private var browserProfilePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.profile.menu.title", defaultValue: "Profiles"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(browserProfileStore.profiles) { profile in
                    Button {
                        applyBrowserProfileSelection(profile.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: profile.id == panel.profileID ? "checkmark" : "circle")
                                .font(.system(size: 10, weight: .semibold))
                                .opacity(profile.id == panel.profileID ? 1.0 : 0.0)
                                .frame(width: 12, alignment: .center)
                            Text(profile.displayName)
                                .font(.system(size: 12))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(profile.id == panel.profileID ? Color.primary.opacity(0.12) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button {
                isBrowserProfileMenuPresented = false
                presentCreateBrowserProfilePrompt()
            } label: {
                Text(String(localized: "browser.profile.new", defaultValue: "New Profile..."))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                presentImportDialogFromProfileMenu()
            } label: {
                Text(String(localized: "menu.view.importFromBrowser", defaultValue: "Import Browser Data…"))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            if browserProfileStore.canRenameProfile(id: panel.profileID) {
                Button {
                    isBrowserProfileMenuPresented = false
                    presentRenameBrowserProfilePrompt()
                } label: {
                    Text(String(localized: "browser.profile.rename", defaultValue: "Rename Current Profile..."))
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, browserProfilePopoverHorizontalPadding)
        .padding(.vertical, browserProfilePopoverVerticalPadding)
        .frame(minWidth: 208)
    }

    private var browserThemeModePopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(BrowserThemeMode.allCases) { mode in
                Button {
                    applyBrowserThemeModeSelection(mode)
                    isBrowserThemeMenuPresented = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode == browserThemeMode ? "checkmark" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(mode == browserThemeMode ? 1.0 : 0.0)
                            .frame(width: 12, alignment: .center)
                        Text(mode.displayName)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(mode == browserThemeMode ? Color.primary.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("BrowserThemeModeOption\(mode.rawValue.capitalized)")
            }
        }
        .padding(8)
        .frame(minWidth: 128)
    }

    private var browserThemeModeIconColor: Color {
        devToolsColorOption.color
    }

}
