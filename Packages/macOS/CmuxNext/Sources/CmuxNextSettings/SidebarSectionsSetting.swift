public import CmuxNextDesign

/// Parses the sidebar section settings (`sidebar.*` in cmux.json). A
/// missing key is its default; a bad value is the default plus a diagnostic.
public nonisolated enum SidebarSectionsSetting {
    public static let lookPath = ["sidebar", "sectionLook"]
    public static let topSharePath = ["sidebar", "topBandMaxShare"]
    public static let bottomSharePath = ["sidebar", "bottomBandMaxShare"]
    public static let scrollPath = ["sidebar", "pinnedBandsScroll"]
    /// R87: the key nightly-next builds wrote before the rename, read for
    /// one release when `sidebar.pinnedBandsScroll` is absent. Remove after it.
    static let legacyScrollPath = ["sidebar", "stickyBandsScroll"]
    public static let showWorkspaceTabsPath = ["sidebar", "showWorkspaceTabs"]
    public static let minimalModePath = ["sidebar", "minimalMode"]
    /// Minimal mode (cx-w1r5): rows draw only icon, name and marks; section
    /// headers become thin lines.
    public static let minimalPath = ["sidebar", "minimal"]
    public static let densityPath = ["sidebar", "density"]
    /// `sidebar.style`: standard or the thin rail (plans/cmux-next/minimal-sidebar.md).
    public static let stylePath = ["sidebar", "style"]
    public static let showProjectsPath = ["sidebar", "showProjects"]
    public static let groupByPath = ["sidebar", "groupBy"]
    public static let showChatsPath = ["sidebar", "showChats"]
    public static let sessionTreePath = ["sidebar", "sessionTree"]
    public static let showSpacesPath = ["sidebar", "showSpaces"]
    public static let showProfileControlPath = ["sidebar", "showProfileControl"]
    public static let showSearchButtonPath = ["sidebar", "showSearchButton"]
    public static let noFadePath = ["sidebar", "noFade"]
    public static let tipsPath = ["sidebar", "cards", "tips"]
    public static let detailedStatusIconsPath = ["sidebar", "detailedStatusIcons"]
    public static let showTimestampsPath = ["sidebar", "showTimestamps"]
    public static let showColorsPath = ["sidebar", "showColors"]
    public static let showLocalMachinePath = ["sidebar", "showLocalMachine"]
    public static let groupHeaderMemberCountPath = ["sidebar", "groupHeader", "memberCount"]
    public static let groupHeaderUnreadCountPath = ["sidebar", "groupHeader", "unreadCount"]

    static func tipsDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(tipsPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.cards.tips", "Show Tips"),
                          help: SettingsText.keyed("settings.sidebar.cards.tips.help",
                                                   "A \"Did you know\" card above the account button shows one cmux feature a day that you have not used yet. Each tip shows only once."),
                          summary: SettingsText.keyed("settings.sidebar.cards.tips.summary", "A daily tip about a feature you haven't used"),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showsTips),
                          keywords: ["sidebar", "tips", "did you know", "cards", "learn", "features"])
    }

    static func minimalDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(minimalPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.minimal", "Minimal Mode"),
                          help: SettingsText.keyed("settings.sidebar.minimal.help",
                                                   "Workspace rows show only their icon, name and unread mark, and section titles become thin lines."),
                          summary: SettingsText.keyed("settings.sidebar.minimal.summary", "Rows show only icon, name and unread mark"),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.minimal),
                          keywords: ["sidebar", "minimal", "compact", "dense", "rows", "simple", "clean"])
    }

    static func detailedStatusIconsDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(detailedStatusIconsPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.detailedStatusIcons", "Detailed Status Icons"),
                          help: SettingsText.keyed("settings.sidebar.detailedStatusIcons.help",
                                                   "Workspace rows show a separate icon for working, waiting for input, error and done. Off, a row shows a spinner while it works and a blue dot when it is ready for you."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.detailedStatusIcons),
                          keywords: ["sidebar", "status", "icons", "badge", "working", "waiting", "input", "error", "done", "agent", "osc 7501"])
    }

    static func showLocalMachineDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(showLocalMachinePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.showLocalMachine", "Mark This Mac's Workspaces"),
                          help: SettingsText.keyed("settings.sidebar.showLocalMachine.help",
                                                   "With workspaces on more than one computer, a workspace on another computer shows that computer's icon in its color. On, this Mac's workspaces show its icon too."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showLocalMachine),
                          keywords: ["sidebar", "machine", "computer", "this mac", "local", "icon", "color", "remote", "identity"])
    }

    static func showColorsDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(showColorsPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.showColors", "Show Workspace Colors"),
                          help: SettingsText.keyed("settings.sidebar.showColors.help",
                                                   "Workspaces and groups draw their colors in the sidebar. Off, the sidebar draws no colors and keeps the colors you set."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showColors),
                          keywords: ["sidebar", "color", "colors", "colour", "tint", "swatch", "group", "workspace", "hide", "plain"])
    }

    static func showTimestampsDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(showTimestampsPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.showTimestamps", "Show Timestamps"),
                          help: SettingsText.keyed("settings.sidebar.showTimestamps.help",
                                                   "Workspace rows show when they last changed: a time today, else an age such as 3d. Off, rows show no times; the hover card still does."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showTimestamps),
                          keywords: ["sidebar", "timestamps", "time", "times", "age", "ago", "elapsed", "duration", "last activity", "clock", "rows"])
    }

    static func groupHeaderMemberCountDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(groupHeaderMemberCountPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.groupHeader.memberCount", "Show Group Member Count"),
                          help: SettingsText.keyed("settings.sidebar.groupHeader.memberCount.help",
                                                   "A collapsed group shows how many workspaces it holds after its name. Off, it shows only its loading spinner."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.groupHeaderMemberCount),
                          keywords: ["sidebar", "group", "groups", "count", "members", "workspaces", "number", "header"])
    }

    static func groupHeaderUnreadCountDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(groupHeaderUnreadCountPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.groupHeader.unreadCount", "Show Group Unread Count"),
                          help: SettingsText.keyed("settings.sidebar.groupHeader.unreadCount.help",
                                                   "A collapsed group shows how many unread notifications its workspaces have. Off, it shows only its loading spinner."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.groupHeaderUnreadCount),
                          keywords: ["sidebar", "group", "groups", "unread", "badge", "notifications", "count", "header"])
    }

    static func densityDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(densityPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.density", "Sidebar Density"),
                          help: SettingsText.keyed("settings.sidebar.density.help",
                                                   "Comfortable rows keep one line on taller rows with more space around them. Expanded rows show each workspace's status or folder under its name, how long ago it changed, and its pull request and computer."),
                          kind: .choice(SidebarDensity.allCases.map { density in
                              switch density {
                              case .compact: SettingChoice(density.rawValue, SettingsText.keyed("settings.choice.compact", "Compact"))
                              case .comfortable: SettingChoice(density.rawValue, SettingsText.keyed("settings.choice.comfortable", "Comfortable"))
                              case .expanded: SettingChoice(density.rawValue, SettingsText.keyed("settings.choice.expanded", "Expanded"))
                              }
                          }),
                          default: .string(SidebarSectionsPreferences.defaults.density.rawValue),
                          keywords: ["sidebar", "density", "expanded", "compact", "comfortable", "rows", "preview", "two lines", "taller", "t3", "codex"])
    }

    static func styleDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(stylePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.style", "Sidebar Style"),
                          help: SettingsText.keyed("settings.sidebar.style.help",
                                                   "Rail shrinks the sidebar to a thin strip with a mark for each workspace. Point at the strip to open the full sidebar over your work."),
                          kind: .choice([
                              SettingChoice(SidebarLayoutStyle.standard.rawValue, SettingsText.keyed("settings.choice.sidebarStandard", "Standard")),
                              SettingChoice(SidebarLayoutStyle.rail.rawValue, SettingsText.keyed("settings.choice.sidebarRail", "Rail")),
                          ]),
                          default: .string(SidebarSectionsPreferences.defaults.style.rawValue),
                          keywords: ["sidebar", "style", "rail", "thin", "narrow", "minimal", "strip", "hide", "hover", "overlay", "auto hide"])
    }

    static func minimalModeDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(minimalModePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.minimalMode", "Hide Bands Until Hover"),
                          help: SettingsText.keyed("settings.sidebar.minimalMode.help",
                                                   "Hides the chosen sections until the pointer is over the sidebar."),
                          kind: .choice([
                              SettingChoice(SidebarMinimalMode.off.rawValue, SettingsText.keyed("settings.choice.off", "Off")),
                              SettingChoice(SidebarMinimalMode.bottom.rawValue,
                                            SettingsText.keyed("settings.choice.minimalBottom", "Settings and Account Row")),
                              SettingChoice(SidebarMinimalMode.top.rawValue, SettingsText.keyed("settings.choice.minimalTop", "Top Sections")),
                              SettingChoice(SidebarMinimalMode.both.rawValue, SettingsText.keyed("settings.choice.minimalBoth", "Top and Bottom")),
                          ]),
                          default: .string(SidebarSectionsPreferences.defaults.minimalMode.rawValue),
                          keywords: ["sidebar", "minimal", "hide", "hover", "settings", "account"])
    }

    static func showWorkspaceTabsDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(showWorkspaceTabsPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.showWorkspaceTabs", "Show Workspace Tabs"),
                          help: SettingsText.keyed("settings.sidebar.showWorkspaceTabs.help", "Lists tabs beneath each workspace in the sidebar."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showWorkspaceTabs),
                          keywords: ["sidebar", "workspace", "tabs"])
    }

    /// Projects, which its header's menu hides (Leo 2026-10-06). All chats has
    /// Show All Chats on New Tab (`showChatsDescriptor`).
    static func sectionDescriptors(group: SettingText) -> [SettingDescriptor] {
        [
            SettingDescriptor(showProjectsPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.showProjects", "Show Projects"),
                              kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showProjects),
                              keywords: ["sidebar", "projects", "workspaces", "section", "hide", "show"]),
            SettingDescriptor(groupByPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.groupBy", "Group Projects By"),
                              kind: .choice([
                                  SettingChoice(SidebarGroupBy.none.rawValue, SettingsText.keyed("settings.choice.groupByNone", "None")),
                                  SettingChoice(SidebarGroupBy.folder.rawValue, SettingsText.keyed("settings.choice.groupByFolder", "Folder")),
                              ]),
                              default: .string(SidebarSectionsPreferences.defaults.groupBy.rawValue),
                              keywords: ["sidebar", "projects", "group", "folder", "directory", "cwd"]),
            // The bottom band's pieces (cx-wab7m): right-click hides each, the band shows it again.
            SettingDescriptor(showSpacesPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.showSpaces", "Show Spaces"),
                              kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showSpaces),
                              keywords: ["sidebar", "spaces", "dots", "profiles", "footer", "hide", "show"]),
            SettingDescriptor(showProfileControlPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.showProfileControl", "Show Profile Button"),
                              kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showProfileControl),
                              keywords: ["sidebar", "profile", "account", "avatar", "footer", "hide", "show"]),
            // The footer's Search button (plans/cmux-next/sidebar-search.md).
            SettingDescriptor(showSearchButtonPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.showSearchButton", "Show Search Button"),
                              help: SettingsText.keyed("settings.sidebar.showSearchButton.help",
                                                       "A magnifying glass after the profile button searches workspaces, tabs, history, agent chats, settings and commands. Off, Search stays in the command palette."),
                              kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showSearchButton),
                              keywords: ["sidebar", "search", "find", "magnifying glass", "everything", "footer", "hide", "show"]),
            // Show Whole Sidebar (No Fade): the list shows with no edge fade and the profile and search bar hides.
            SettingDescriptor(noFadePath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.noFade", "Show Whole Sidebar Without Fade"),
                              help: SettingsText.keyed("settings.sidebar.noFade.help",
                                                       "The sidebar's edges stop fading and the whole list shows. It also hides the bottom profile and search bar. Off, the edges fade and the bar shows."),
                              kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.noFade),
                              keywords: ["sidebar", "fade", "whole", "full", "everything", "edges", "profile", "search", "footer", "show", "hide"]),
        ]
    }

    static func sessionTreeDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(sessionTreePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.sessionTree", "Session Tree"),
                          help: SettingsText.keyed("settings.sidebar.sessionTree.help",
                                                   "Lists a workspace that another workspace's agent started under it, and shows each row's pull requests and the first rows' Command-number keys."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.sessionTree),
                          keywords: ["sidebar", "tree", "nested", "parent", "child", "pull request", "keycap", "sessions"])
    }

    static func showChatsDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(showChatsPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.showChats", "Show All Chats on New Tab"),
                          help: SettingsText.keyed("settings.sidebar.showChats.help",
                                                   "On the New Tab page, the Threads and Console styles list every coding agent chat on this computer, newest first. Off, they show the recent chats only."),
                          kind: .toggle, default: .bool(SidebarSectionsPreferences.defaults.showChats),
                          keywords: ["new tab", "chats", "all chats", "agents", "conversations", "history", "threads", "console"])
    }

    /// The looks the setting accepts (CmuxNextSidebar.SectionsLookVariant).
    public static let looks = ["quiet", "card", "tray", "lines", "linesIcons"]

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SidebarSectionsPreferences {
        var result = SidebarSectionsPreferences.defaults
        if let value = root.value(at: lookPath) {
            if let text = value.stringValue, looks.contains(text) {
                result.look = text
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.sectionLook",
                                                      message: "expected one of " + looks.map { "\"\($0)\"" }.joined(separator: ", ")))
            }
        }
        result.topBandMaxShare = share(root, topSharePath, "sidebar.topBandMaxShare", fallback: result.topBandMaxShare, &diagnostics)
        result.bottomBandMaxShare = share(root, bottomSharePath, "sidebar.bottomBandMaxShare", fallback: result.bottomBandMaxShare, &diagnostics)
        // Together the shares leave the list at least a fifth: past 0.8 both
        // shrink in proportion (each value alone stays valid, so setting one
        // never needs the other changed first).
        let sum = result.topBandMaxShare + result.bottomBandMaxShare
        if sum > SidebarSectionsPreferences.maxShareSum {
            let scale = SidebarSectionsPreferences.maxShareSum / sum
            result.topBandMaxShare *= scale
            result.bottomBandMaxShare *= scale
        }
        let scroll = ColumnLayoutSettings.path(root, scrollPath, legacy: legacyScrollPath)
        if let value = root.value(at: scroll) {
            if let flag = value.boolValue {
                result.pinnedBandsScroll = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: scroll.joined(separator: "."), message: "expected true or false"))
            }
        }
        if let value = root.value(at: minimalModePath) {
            if let text = value.stringValue, let mode = SidebarMinimalMode(rawValue: text) {
                result.minimalMode = mode
            } else {
                let choices = SidebarMinimalMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.minimalMode", message: "expected one of " + choices))
            }
        }
        if let value = root.value(at: showWorkspaceTabsPath) {
            if let flag = value.boolValue {
                result.showWorkspaceTabs = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.showWorkspaceTabs", message: "expected true or false"))
            }
        }
        result.sessionTree = flag(root, sessionTreePath, fallback: result.sessionTree, &diagnostics)
        if let value = root.value(at: tipsPath) {
            if let flag = value.boolValue {
                result.showsTips = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.cards.tips", message: "expected true or false"))
            }
        }
        SidebarNavigationSetting.parse(root, into: &result.navigation, diagnostics: &diagnostics)
        result.workspaceRow = WorkspaceRowSetting().parse(root, diagnostics: &diagnostics)
        result.showProjects = flag(root, showProjectsPath, fallback: result.showProjects, &diagnostics)
        result.showSpaces = flag(root, showSpacesPath, fallback: result.showSpaces, &diagnostics)
        result.showProfileControl = flag(root, showProfileControlPath, fallback: result.showProfileControl, &diagnostics)
        result.showSearchButton = flag(root, showSearchButtonPath, fallback: result.showSearchButton, &diagnostics)
        result.noFade = flag(root, noFadePath, fallback: result.noFade, &diagnostics)
        result.minimal = flag(root, minimalPath, fallback: result.minimal, &diagnostics)
        result.detailedStatusIcons = flag(root, detailedStatusIconsPath, fallback: result.detailedStatusIcons, &diagnostics)
        result.showTimestamps = flag(root, showTimestampsPath, fallback: result.showTimestamps, &diagnostics)
        result.showColors = flag(root, showColorsPath, fallback: result.showColors, &diagnostics)
        result.workspaceColorIndicator = WorkspaceColorsSetting.parseIndicatorStyle(root, fallback: result.workspaceColorIndicator, &diagnostics)
        result.showLocalMachine = flag(root, showLocalMachinePath, fallback: result.showLocalMachine, &diagnostics)
        result.groupHeaderMemberCount = flag(root, groupHeaderMemberCountPath, fallback: result.groupHeaderMemberCount, &diagnostics)
        result.groupHeaderUnreadCount = flag(root, groupHeaderUnreadCountPath, fallback: result.groupHeaderUnreadCount, &diagnostics)
        result.priorityViewEnabled = flag(root, SidebarPriorityViewSetting.enabledPath, fallback: result.priorityViewEnabled, &diagnostics)
        result.priorityViewShown = flag(root, SidebarPriorityViewSetting.shownPath, fallback: result.priorityViewShown, &diagnostics)
        if let value = root.value(at: groupByPath) {
            if let text = value.stringValue, let groupBy = SidebarGroupBy(rawValue: text) {
                result.groupBy = groupBy
            } else {
                let choices = SidebarGroupBy.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.groupBy", message: "expected one of " + choices))
            }
        }
        if let value = root.value(at: densityPath) {
            if let text = value.stringValue, let density = SidebarDensity(rawValue: text) {
                result.density = density
            } else {
                let choices = SidebarDensity.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.density", message: "expected one of " + choices))
            }
        }
        if let value = root.value(at: stylePath) {
            if let text = value.stringValue, let style = SidebarLayoutStyle(rawValue: text) {
                result.style = style
            } else {
                let choices = SidebarLayoutStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.style", message: "expected one of " + choices))
            }
        }
        if let value = root.value(at: showChatsPath) {
            if let flag = value.boolValue {
                result.showChats = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.showChats", message: "expected true or false"))
            }
        }
        return result
    }

    private static func flag(_ root: JSONValue, _ path: [String], fallback: Bool, _ diagnostics: inout [SettingsDiagnostic]) -> Bool {
        guard let value = root.value(at: path) else { return fallback }
        guard let flag = value.boolValue else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false"))
            return fallback
        }
        return flag
    }

    private static func share(_ root: JSONValue, _ path: [String], _ name: String, fallback: Double,
                              _ diagnostics: inout [SettingsDiagnostic]) -> Double {
        guard let value = root.value(at: path) else { return fallback }
        guard let number = value.doubleValue, SidebarSectionsPreferences.shareRange.contains(number) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: name,
                                                  message: "expected a share of the sidebar height from 0.1 to 0.9, such as 0.33"))
            return fallback
        }
        return number
    }
}
