Verification evidence for cmux PR #11419

App source: af27da70e4a5ba113dab23f190b1f382b29aae18
PR HEAD: 94ccc1828a4df6e1b8e5374ec3859ea79fe89f62
The final main merge changes only web build/test files; native sources are identical.

Before: the desktop and both clients use 94x37.
After: persistent client A uses a 20x6 projection; the desktop, PTY, and client B stay 94x37.
The screenshots intentionally show unchanged desktop content. They do not establish iPhone rendering or authenticated transport behavior. runtime-verification.json includes the projected text and connection/CLI checks.

Images are unedited Cua app-state captures from the actual tagged app. The checks used real persistent socket connections and the checked-in tag-bound CLI helper.
