// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation

/// Normalized `cmux.ui-surface/1` samples for the mock chat, previews and tests, written from
/// plans/cmux-next/agent-ui-surfaces-DESIGN.md (no cmux-ui-surfaces golden files existed when they
/// were written; swap them for `cmux-tui/crates/cmux-ui-surfaces/tests/golden/*.json` once those land).
/// `travelerForm` is the A2UI quickstart's `70-traveler-form` as Rust normalizes it.
struct UISurfaceFixtures {
    /// A group of cards the mock replays as one turn (`-cmux-mobile-demo ui-surfaces-<scene>`).
    enum Scene: String, CaseIterable {
        case approval, review, data, charts, form

        var prompt: String {
            switch self {
            case .approval: "Ask me before each risky step."
            case .review: "Give me some options to pick from."
            case .data: "How did the last builds do?"
            case .charts: "Chart the build times."
            case .form: "Book the Lisbon trip for me."
            }
        }

        var surfaces: [JSONValue] {
            switch self {
            case .approval: [UISurfaceFixtures.approvalCompact, UISurfaceFixtures.approvalFull, UISurfaceFixtures.approvalDanger].map(UISurfaceFixtures.json)
            case .review: [UISurfaceFixtures.reviewChips, UISurfaceFixtures.reviewList, UISurfaceFixtures.reviewRanked].map(UISurfaceFixtures.json)
            case .data: [UISurfaceFixtures.table, UISurfaceFixtures.barChart, UISurfaceFixtures.progress].map(UISurfaceFixtures.json)
            case .charts: [UISurfaceFixtures.lineChart, UISurfaceFixtures.pieChart, UISurfaceFixtures.claimedError].map(UISurfaceFixtures.json)
            case .form: [UISurfaceFixtures.travelerForm, UISurfaceFixtures.travelerFormPending, UISurfaceFixtures.streaming, UISurfaceFixtures.mcpApp].map(UISurfaceFixtures.json)
            }
        }
    }

    /// Every sample, by name (previews and tests).
    static var all: [(name: String, surface: JSONValue)] {
        [("approvalCompact", approvalCompact), ("approvalFull", approvalFull), ("approvalDanger", approvalDanger),
         ("reviewChips", reviewChips), ("reviewList", reviewList), ("reviewRanked", reviewRanked),
         ("table", table), ("barChart", barChart), ("lineChart", lineChart), ("pieChart", pieChart),
         ("progress", progress), ("streaming", streaming), ("travelerForm", travelerForm),
         ("travelerFormPending", travelerFormPending), ("mcpApp", mcpApp), ("claimedError", claimedError)]
            .map { ($0.0, json($0.1)) }
    }

    static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    // MARK: Approvals

    static let approvalCompact = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"ap-compact","status":"ready",
     "source":{"kind":"a2ui","server":"cmux","tool":"ui_surface","catalogId":"https://cmux.com/a2ui/catalog/v1"},
     "root":{"id":"a","type":"approval","title":"Run the test suite now?","risk":"low","facts":[],
             "approve":{"id":"a-yes","name":"approve","privileged":true},"deny":{"id":"a-no","name":"deny"}}}
    """#

    static let approvalFull = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"ap-full","status":"ready","title":"Deploy preview",
     "source":{"kind":"a2ui","server":"deploys","tool":"request_deploy","catalogId":"https://cmux.com/a2ui/catalog/v1"},
     "root":{"id":"a","type":"approval","title":"Deploy lane/link-framing to the preview site?","risk":"medium",
             "detail":"The preview replaces what is there now. Nobody else is on it.",
             "facts":[{"label":"Branch","value":"lane/link-framing"},{"label":"Commit","value":"4d81e0c"},
                      {"label":"Site","value":"preview-3"},{"label":"Takes","value":"about 4 minutes"}],
             "approve":{"id":"a-yes","name":"approve","privileged":true},"deny":{"id":"a-no","name":"deny"}}}
    """#

    static let approvalDanger = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"ap-danger","status":"ready",
     "source":{"kind":"a2ui","server":"cmux","tool":"ui_surface"},
     "root":{"id":"a","type":"approval","title":"Delete branch lane/old-work and its worktree","risk":"high",
             "detail":"3 commits on it are on no other branch. They can't be brought back.",
             "facts":[{"label":"Branch","value":"lane/old-work"},{"label":"Worktree","value":"~/code/cmux-old-work"},
                      {"label":"Unpushed","value":"3 commits"}],
             "approve":{"id":"a-yes","name":"approve","privileged":true},"deny":{"id":"a-no","name":"deny"},
             "a11y":{"description":"High risk: deletes commits that exist nowhere else."}}}
    """#

    // MARK: Reviews

    static let reviewChips = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"rv-chips","status":"ready",
     "source":{"kind":"a2ui","server":"cmux","tool":"ui_surface"},
     "root":{"id":"r","type":"review","title":"Name the new setting","prompt":"Pick one; I'll use it everywhere.",
             "options":[{"id":"cards","label":"Interactive cards"},{"id":"views","label":"Agent views"},
                        {"id":"surfaces","label":"UI surfaces"}],
             "submit":{"id":"r-go","name":"submit","privileged":true}}}
    """#

    static let reviewList = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"rv-list","status":"ready",
     "source":{"kind":"a2ui","server":"cmux","tool":"ui_surface"},
     "root":{"id":"r","type":"review","title":"How should I fix the flaky test?",
             "options":[{"id":"retry","label":"Retry once on timeout","detail":"Quick; hides a slow link."},
                        {"id":"clock","label":"Inject the clock","detail":"A real fix; touches 4 files."},
                        {"id":"skip","label":"Skip it on CI for now","detail":"Files an issue to come back."}],
             "submit":{"id":"r-go","name":"submit","privileged":true}}}
    """#

    static let reviewRanked = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"rv-ranked","status":"ready",
     "source":{"kind":"a2ui","server":"triage","tool":"rank_issues"},
     "root":{"id":"r","type":"review","title":"Which issues go in this week?","prompt":"Most important first. Pick any.",
             "multi":true,"bind":"/picked",
             "options":[{"id":"i1","label":"Chat jumps while a card streams","detail":"12 reports, iPhone and Mac"},
                        {"id":"i2","label":"Approvals time out on LTE","detail":"5 reports"},
                        {"id":"i3","label":"Table cells wrap badly","detail":"3 reports"},
                        {"id":"i4","label":"Chart colors in light mode","detail":"2 reports"},
                        {"id":"i5","label":"VoiceOver reads chart twice","detail":"1 report"}],
             "value":["i1"],
             "submit":{"id":"r-go","name":"submit","privileged":true}}}
    """#

    // MARK: Table, charts, progress

    static let table = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"tb","status":"ready","title":"Last builds",
     "source":{"kind":"a2ui","server":"ci","tool":"recent_builds","catalogId":"https://cmux.com/a2ui/catalog/v1"},
     "root":{"id":"t","type":"table","truncated":false,
             "columns":[{"key":"run","label":"Run"},{"key":"branch","label":"Branch"},{"key":"status","label":"Status"},
                        {"key":"time","label":"Time","align":"right"},{"key":"tests","label":"Tests","align":"right"},
                        {"key":"host","label":"Host"}],
             "rows":[["#4812","lane/link-framing","passed","11m 02s","1,204","aws-m4pro-3"],
                     ["#4811","feat-cmux-next","passed","10m 41s","1,204","aws-m4pro-1"],
                     ["#4810","lane/a2ui-native-cards","failed","6m 13s","988","aws-m4pro-5"],
                     ["#4809","lane/relay-probe","passed","12m 30s","1,199","aws-m4pro-2"],
                     ["#4808","feat-cmux-next","cancelled","1m 05s","0","aws-m4pro-4"]]}}
    """#

    static let barChart = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"ch-bar","status":"ready","title":"Tests per day",
     "source":{"kind":"a2ui","server":"ci","tool":"test_counts"},
     "root":{"id":"c","type":"chart","kind":"bar","yLabel":"Tests",
             "series":[{"name":"Passed","points":[{"x":"Mon","y":1180},{"x":"Tue","y":1192},{"x":"Wed","y":1201},{"x":"Thu","y":1199}]},
                       {"name":"Failed","points":[{"x":"Mon","y":24},{"x":"Tue","y":12},{"x":"Wed","y":3},{"x":"Thu","y":5}]}],
             "a11y":{"label":"Tests per day, passed and failed, Monday to Thursday"}}}
    """#

    static let lineChart = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"ch-line","status":"ready","title":"Build minutes",
     "source":{"kind":"a2ui","server":"ci","tool":"build_times"},
     "root":{"id":"c","type":"chart","kind":"line","yLabel":"Minutes",
             "series":[{"name":"Mac","points":[{"x":1,"y":14.2},{"x":2,"y":12.8},{"x":3,"y":11.1},{"x":4,"y":11.4},{"x":5,"y":10.7}]},
                       {"name":"iPhone","points":[{"x":1,"y":16.0},{"x":2,"y":15.1},{"x":3,"y":15.4},{"x":4,"y":13.9},{"x":5,"y":12.2}]}]}}
    """#

    static let pieChart = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"ch-pie","status":"ready","title":"Where the time went",
     "source":{"kind":"a2ui","server":"ci","tool":"build_times"},
     "root":{"id":"c","type":"chart","kind":"pie","yLabel":"Minutes",
             "series":[{"name":"Steps","points":[{"x":"Compile","y":6.1},{"x":"Tests","y":3.2},{"x":"Sign","y":0.9},{"x":"Upload","y":0.5}]}]}}
    """#

    static let progress = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"pg","status":"ready","title":"Release 0.42",
     "source":{"kind":"a2ui","server":"cmux","tool":"ui_surface"},
     "root":{"id":"s","type":"stack","axis":"v","children":[
       {"id":"p1","type":"progress","label":"Build the Mac app","state":"done","value":100,"max":100},
       {"id":"p2","type":"progress","label":"Notarize","state":"running","value":60,"max":100,
        "a11y":{"live":"polite"}},
       {"id":"p3","type":"progress","label":"Upload to TestFlight","state":"running"},
       {"id":"p4","type":"progress","label":"Screenshots","state":"failed","value":3,"max":8}]}}
    """#

    // MARK: Forms and states

    /// The quickstart's `70-traveler-form` (an A2UI `createSurface` in the travel catalog), as Rust
    /// normalizes it: the Markdown heading becomes a heading, each `@path` value a bind, the button's
    /// `event` an action (privileged: it sends the data model).
    static let travelerForm = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"inline-5","status":"ready",
     "source":{"kind":"a2ui","server":"quickstart","tool":"ui_surface",
               "catalogId":"https://travel-a2ui.dev/catalogs/a2ui-travel/catalog.json"},
     "root":{"id":"root","type":"stack","axis":"v","children":[
       {"id":"title","type":"text","style":"heading","text":"Who is travelling?"},
       {"id":"name","type":"field","input":"text","label":"Full name (as on passport)","bind":"/traveler/name"},
       {"id":"email","type":"field","input":"text","label":"Email","bind":"/traveler/email"},
       {"id":"seat","type":"field","input":"choice","label":"Seat","bind":"/traveler/seat",
        "options":[{"value":"window","label":"Window"},{"value":"aisle","label":"Aisle"}]},
       {"id":"save","type":"button","label":"Save traveller","variant":"primary",
        "action":{"id":"a1","name":"save_traveler","privileged":true}}]}}
    """#

    /// The traveler form after Save: Rust's Pending, waiting for Confirm.
    static let travelerFormPending = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"inline-6","status":"ready",
     "source":{"kind":"a2ui","server":"quickstart","tool":"ui_surface"},
     "root":{"id":"root","type":"stack","axis":"v","children":[
       {"id":"title","type":"text","style":"heading","text":"Who is travelling?"},
       {"id":"name","type":"field","input":"text","label":"Full name (as on passport)","bind":"/traveler/name","value":"Ada Lovelace"},
       {"id":"email","type":"field","input":"text","label":"Email","bind":"/traveler/email","value":"ada@example.com"},
       {"id":"seat","type":"field","input":"choice","label":"Seat","bind":"/traveler/seat","value":"window",
        "options":[{"value":"window","label":"Window"},{"value":"aisle","label":"Aisle"}]},
       {"id":"bags","type":"field","input":"slider","label":"Checked bags","bind":"/traveler/bags","value":1,"min":0,"max":3},
       {"id":"date","type":"field","input":"date","label":"Leaving","bind":"/trip/date","value":"2026-12-04"},
       {"id":"meal","type":"field","input":"checkbox","label":"Vegetarian meal","bind":"/traveler/veg","value":true},
       {"id":"airport","type":"fallback","text":"AirportPicker (travel catalog)"},
       {"id":"save","type":"button","label":"Save traveller","variant":"primary",
        "action":{"id":"a1","name":"save_traveler","privileged":true}}]},
     "pending":{"requestId":"r7","actionId":"a1",
                "summary":"Send \"save_traveler\" to the agent with: name = Ada Lovelace, email = ada@example.com, seat = window",
                "sends":[{"label":"name","value":"Ada Lovelace"},{"label":"email","value":"ada@example.com"},
                         {"label":"seat","value":"window"}],
                "target":"agent"}}
    """#

    /// A surface still streaming in: its first components, more to come.
    static let streaming = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"st","status":"streaming","title":"Flights to Lisbon",
     "source":{"kind":"a2ui","server":"quickstart","tool":"ui_surface"},
     "root":{"id":"root","type":"list","children":[
       {"id":"f1","type":"stack","axis":"h","children":[
         {"id":"f1i","type":"icon","name":"send"},
         {"id":"f1t","type":"text","text":"TP 1351 · 07:10 → 09:05 · €182"}]},
       {"id":"f2","type":"stack","axis":"h","children":[
         {"id":"f2i","type":"icon","name":"send"},
         {"id":"f2t","type":"text","text":"FR 7302 · 12:40 → 14:30 · €96"}]},
       {"id":"img","type":"image","alt":"Map of the two routes over Spain"}]}}
    """#

    /// An MCP App's HTML view: the phone shows "open on Mac".
    static let mcpApp = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"app","status":"ready","title":"Get the time",
     "source":{"kind":"mcp-app","server":"quickstart","tool":"get-time","resourceUri":"ui://get-time/mcp-app.html"},
     "frame":{"html":"<p>…</p>","csp":"default-src 'none'","height":320}}
    """#

    /// A server the person did not connect ("claimed"), whose surface failed part way.
    static let claimedError = #"""
    {"schema":"cmux.ui-surface/1","surfaceId":"err","status":"error","error":"The server stopped sending this card.",
     "source":{"kind":"a2ui","server":"weather-helper","tool":"forecast","verified":false},
     "root":{"id":"root","type":"card","children":[
       {"id":"t","type":"text","text":"Lisbon, Friday","style":"heading"},
       {"id":"v","type":"fallback","text":"Video (not in this prototype)"},
       {"id":"x","type":"marquee","text":"unknown node"}]}}
    """#
}
#endif
