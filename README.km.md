<h1 align="center">cmux</h1>
<p align="center">Terminal សម្រាប់ macOS ផ្អែកលើ Ghostty ដែលមាន tab បញ្ឈរ និងការជូនដំណឹងសម្រាប់ AI coding agents</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Download cmux for macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | ភាសាខ្មែរ
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux screenshot" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ វីដេអូបង្ហាញពីដំណើរការ (Demo)</a> · <a href="https://cmux.dev/blog/zen-of-cmux">ទស្សនវិជ្ជារបស់ cmux (The Zen of cmux)</a>
</p>

## លក្ខណៈពិសេសនានា (Features)

<table>
<tr>
<td width="40%" valign="middle">
<h3>Notification rings</h3>
Panes get a blue ring and tabs light up when coding agents need your attention
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Notification rings" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Notification panel</h3>
See all pending notifications in one place, jump to the most recent unread
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Sidebar notification badge" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>In-app browser</h3>
Split a browser alongside your terminal with a scriptable API ported from <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Built-in browser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Vertical + horizontal tabs</h3>
Sidebar shows git branch, linked PR status/number, working directory, listening ports, and latest notification text. Split horizontally and vertically.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertical tabs and split panes" width="100%" />
</td>
</tr>
</table>

* **អាចសរសេរ Script បាន (Scriptable)** — CLI និង socket API ដើម្បីបង្កើត workspaces, បំបែក panes, បញ្ជូន keystrokes, និងធ្វើស្វ័យប្រវត្តិកម្មកម្មវិធីរុករក (browser)
* **កម្មវិធីដើមរបស់ macOS (Native macOS app)** — បង្កើតឡើងដោយប្រើ Swift និង AppKit មិនមែន Electron ទេ។ ចាប់ផ្តើមលឿន, ស៊ីមេម៉ូរី (memory) តិច។
* **ត្រូវគ្នាជាមួយ Ghostty (Ghostty compatible)** — អានការកំណត់ `~/.config/ghostty/config` ដែលអ្នកមានស្រាប់សម្រាប់ theme, font, និងពណ៌
* **បង្កើនល្បឿនដោយ GPU (GPU-accelerated)** — ដំណើរការដោយ libghostty ដើម្បីការបង្ហាញរូបភាពរលូនល្អ (smooth rendering)

## ការដំឡើង (Install)

### DMG (ត្រូវបានណែនាំ)

បើកឯកសារ `.dmg` ហើយអូស cmux បញ្ចូលទៅក្នុងថត Applications របស់អ្នក។ cmux ធ្វើបច្ចុប្បន្នភាពដោយស្វ័យប្រវត្តិតាមរយៈ Sparkle ដូច្នេះអ្នកគ្រាន់តែទាញយកវាតែម្តងគត់។

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

ដើម្បីធ្វើបច្ចុប្បន្នភាពនៅពេលក្រោយ៖

```bash
brew upgrade --cask cmux
```

នៅពេលបើកដំណើរការជាលើកដំបូង macOS អាចនឹងសុំឱ្យអ្នកបញ្ជាក់ការបើកកម្មវិធីពីអ្នកអភិវឌ្ឍន៍ដែលបានកំណត់អត្តសញ្ញាណ។ ចុច **Open** ដើម្បីបន្ត។

## ហេតុអ្វីត្រូវជ្រើសរើស cmux?

ខ្ញុំបើកដំណើរការ Claude Code និង Codex ច្រើនក្នុងពេលតែមួយ។ ខ្ញុំធ្លាប់ប្រើ Ghostty ជាមួយ split panes ជាច្រើន ហើយពឹងផ្អែកលើការជូនដំណឹងដើមរបស់ macOS ដើម្បីដឹងថានៅពេលណាដែល agent ត្រូវការខ្ញុំ។ ប៉ុន្តែខ្លឹមសារជូនដំណឹងរបស់ Claude Code តែងតែសរសេរត្រឹម "Claude វាកំពុងរង់ចាំការបញ្ចូលព័ត៌មានពីអ្នក" ដោយគ្មានបរិបទ (context) ហើយនៅពេលដែលបើក tab ច្រើនពេក ខ្ញុំសឹងតែមិនអាចអានចំណងជើងបានទៀតផង។

ខ្ញុំបានសាកល្បងប្រើ coding orchestrators មួយចំនួន ប៉ុន្តែភាគច្រើននៃពួកវាគឺជាកម្មវិធី Electron/Tauri ហើយដំណើរការ (performance) របស់វារំខានដល់ខ្ញុំ។ ម្យ៉ាងទៀត ខ្ញុំចូលចិត្តប្រើ terminal ជាង ពីព្រោះ GUI orchestrators តែងតែកំណត់លំហូរការងារ (workflow) របស់អ្នក។ ដូច្នេះ ខ្ញុំបានបង្កើត cmux ជាកម្មវិធីដើមសម្រាប់ macOS នៅក្នុង Swift/AppKit។ វាប្រើប្រាស់ libghostty សម្រាប់ការបង្ហាញ terminal និងអាន config របស់ Ghostty ដែលអ្នកមានស្រាប់សម្រាប់ themes, fonts និងពណ៌។

ការបន្ថែមដ៏សំខាន់គឺរបារចំហៀង (sidebar) និងប្រព័ន្ធជូនដំណឹង។ របារចំហៀងមាន tab បញ្ឈរដែលបង្ហាញពី git branch, ស្ថានភាព/លេខ PR, ថតការងារ, port ដែលកំពុងស្តាប់ និងអត្ថបទជូនដំណឹងចុងក្រោយសម្រាប់ workspace នីមួយៗ។ ប្រព័ន្ធជូនដំណឹងចាប់យក terminal sequences (OSC 9/99/777) និងមាន CLI (`cmux notify`) ដែលអ្នកអាចភ្ជាប់ទៅកាន់ agent hooks សម្រាប់ Claude Code, OpenCode ជាដើម។ នៅពេល agent កំពុងរង់ចាំ ផ្ទាំង (pane) របស់វានឹងមានរង្វង់ពណ៌ខៀវ ហើយ tab នឹងភ្លឺឡើងនៅលើរបារចំហៀង ដូច្នេះខ្ញុំអាចដឹងថាមួយណាដែលត្រូវការខ្ញុំនៅទូទាំង splits និង tabs ទាំងអស់។ ចុច Cmd+Shift+U ដើម្បីលោតទៅកាន់សារមិនទាន់អានថ្មីបំផុត។

កម្មវិធីរុករកក្នុងកម្មវិធី (in-app browser) មាន scriptable API ដែលបានយកចេញពី [agent-browser](https://github.com/vercel-labs/agent-browser)។ Agents អាចថតចម្លង (snapshot) ដើមឈើភាពងាយស្រួល (accessibility tree), យក element refs, ចុច (click), បំពេញទម្រង់បែបបទ (fill forms) និងវាយតម្លៃ (evaluate) JS។ អ្នកអាចបំបែកផ្ទាំងកម្មវិធីរុករកនៅក្បែរ terminal របស់អ្នក ហើយឱ្យ Claude Code ប្រាស្រ័យទាក់ទងដោយផ្ទាល់ជាមួយ dev server របស់អ្នក។

អ្វីៗទាំងអស់អាចសរសេរ script បានតាមរយៈ CLI និង socket API — បង្កើត workspaces/tabs, បំបែក panes, បញ្ជូន keystrokes, បើក URLs នៅក្នុងកម្មវិធីរុករក។

## ទស្សនវិជ្ជារបស់ cmux (The Zen of cmux)

cmux មិនបង្ខំអំពីរបៀបដែលអ្នកអភិវឌ្ឍន៍ប្រើប្រាស់ឧបករណ៍របស់ពួកគេទេ។ វាគឺជា terminal និងកម្មវិធីរុករកដែលមាន CLI ហើយអ្វីៗផ្សេងទៀតគឺអាស្រ័យលើអ្នក។

cmux គឺជាមូលដ្ឋានគ្រឹះ (primitive) មិនមែនជាដំណោះស្រាយពេញលេញទេ។ វាផ្តល់ឱ្យអ្នកនូវ terminal, កម្មវិធីរុករក, ការជូនដំណឹង, workspaces, splits, tabs និង CLI ដើម្បីគ្រប់គ្រងអ្វីៗទាំងអស់នេះ។ cmux មិនបង្ខំអ្នកឱ្យប្រើវិធីសាស្ត្រណាមួយដែលវាបានកំណត់ទុកមុនក្នុងការប្រើប្រាស់ coding agents នោះទេ។ អ្វីដែលអ្នកបង្កើតជាមួយមូលដ្ឋានគ្រឹះទាំងនេះ គឺជារបស់អ្នក។

អ្នកអភិវឌ្ឍន៍ដ៏ល្អបំផុតតែងតែបង្កើតឧបករណ៍ដោយខ្លួនឯង។ មិនទាន់មាននរណាម្នាក់រកឃើញវិធីល្អបំផុតក្នុងការធ្វើការជាមួយ agents នៅឡើយទេ ហើយក្រុមដែលបង្កើតផលិតផលបិទជិត (closed products) ក៏ច្បាស់ជាមិនទាន់រកឃើញដូចគ្នា។ អ្នកអភិវឌ្ឍន៍ដែលយល់ច្បាស់ពី codebases របស់ពួកគេ នឹងរកឃើញវាមុនគេ។

ផ្តល់ឱ្យអ្នកអភិវឌ្ឍន៍មួយលាននាក់នូវមូលដ្ឋានគ្រឹះដែលអាចផ្សំបញ្ចូលគ្នាបាន នោះពួកគេរួមគ្នានឹងស្វែងរកលំហូរការងារដែលមានប្រសិទ្ធភាពបំផុត លឿនជាងក្រុមការងារផលិតផលណាមួយអាចរចនាពីលើចុះក្រោម (top-down) ទៅទៀត។

## ឯកសារ (Documentation)

សម្រាប់ព័ត៌មានបន្ថែមអំពីរបៀបកំណត់រចនាសម្ព័ន្ធ cmux, [សូមចូលទៅកាន់ឯកសាររបស់យើង](https://cmux.dev/docs/getting-started?utm_source=readme)។

## គ្រាប់ចុចផ្លូវកាត់ (Keyboard Shortcuts)

### តំបន់ការងារ (Workspaces)

| ផ្លូវកាត់ (Shortcut) | សកម្មភាព (Action) |
|---|---|
| ⌘ N | បង្កើត workspace ថ្មី |
| ⌘ 1–8 | លោតទៅ workspace ទី 1–8 |
| ⌘ 9 | លោតទៅ workspace ចុងក្រោយ |
| ⌃ ⌘ ] | workspace បន្ទាប់ |
| ⌃ ⌘ [ | workspace មុន |
| ⌘ ⇧ W | បិទ workspace |
| ⌘ ⇧ R | ប្តូរឈ្មោះ workspace |
| ⌘ B | បិទ/បើក របារចំហៀង |

### ផ្ទៃ (Surfaces)

| ផ្លូវកាត់ (Shortcut) | សកម្មភាព (Action) |
|---|---|
| ⌘ T | បង្កើត surface ថ្មី |
| ⌘ ⇧ ] | surface បន្ទាប់ |
| ⌘ ⇧ [ | surface មុន |
| ⌃ Tab | surface បន្ទាប់ |
| ⌃ ⇧ Tab | surface មុន |
| ⌃ 1–8 | លោតទៅ surface ទី 1–8 |
| ⌃ 9 | លោតទៅ surface ចុងក្រោយ |
| ⌘ W | បិទ surface |

### បំបែកផ្ទាំង (Split Panes)

| ផ្លូវកាត់ (Shortcut) | សកម្មភាព (Action) |
|---|---|
| ⌘ D | បំបែកទៅស្តាំ |
| ⌘ ⇧ D | បំបែកចុះក្រោម |
| ⌥ ⌘ ← → ↑ ↓ | ផ្ដោតលើ pane តាមទិសដៅ |
| ⌘ ⇧ H | បញ្ចេញពន្លឺលើ panel ដែលកំពុងផ្ដោត |

### កម្មវិធីរុករក (Browser)

Browser developer-tool shortcuts follow Safari defaults and are customizable in `Settings → Keyboard Shortcuts`.

| ផ្លូវកាត់ (Shortcut) | សកម្មភាព (Action) |
|---|---|
| ⌘ ⇧ L | បើកកម្មវិធីរុករកក្នុងលក្ខណៈបំបែក (split) |
| ⌘ L | ផ្ដោតលើរបារអាសយដ្ឋាន |
| ⌘ [ | ថយក្រោយ |
| ⌘ ] | ទៅមុខ |
| ⌘ R | ផ្ទុកទំព័រឡើងវិញ |
| ⌥ ⌘ I | បិទ/បើក ឧបករណ៍អ្នកអភិវឌ្ឍន៍ (លំនាំដើម Safari) |
| ⌥ ⌘ C | បង្ហាញ JavaScript Console (លំនាំដើម Safari) |

### ការជូនដំណឹង (Notifications)

| ផ្លូវកាត់ (Shortcut) | សកម្មភាព (Action) |
|---|---|
| ⌘ I | បង្ហាញផ្ទាំងជូនដំណឹង |
| ⌘ ⇧ U | លោតទៅសារមិនទាន់អានថ្មីបំផុត |

### ស្វែងរក (Find)

| ផ្លូវកាត់ (Shortcut) | សកម្មភាព (Action) |
|---|---|
| ⌘ F | ស្វែងរក |
| ⌘ G / ⌘ ⇧ G | ស្វែងរកបន្ទាប់ / មុន |
| ⌘ ⇧ F | លាក់របារស្វែងរក |
| ⌘ E | ប្រើអត្ថបទដែលបានជ្រើសរើសដើម្បីស្វែងរក |

### Terminal

| ផ្លូវកាត់ (Shortcut) | សកម្មភាព (Action) |
|---|---|
| ⌘ K | សម្អាត scrollback |
| ⌘ C | ចម្លង (ជាមួយនឹងការជ្រើសរើស) |
| ⌘ V | ដាក់បញ្ចូល (Paste) |
| ⌘ + / ⌘ - | បង្កើន / បន្ថយ ទំហំអក្សរ |
| ⌘ 0 | កំណត់ទំហំអក្សរឡើងវិញ |

### ផ្ទាំងវីនដូ (Window)

| ផ្លូវកាត់ (Shortcut) | សកម្មភាព (Action) |
|---|---|
| ⌘ ⇧ N | បង្កើតវីនដូថ្មី |
| ⌘ , | ការកំណត់ (Settings) |
| ⌘ ⇧ , | ផ្ទុកការកំណត់ឡើងវិញ (Reload configuration) |
| ⌘ Q | ចាកចេញ |

## កំណែ Nightly Builds

[ទាញយក cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY គឺជាកម្មវិធីដាច់ដោយឡែកមួយដែលមាន bundle ID ផ្ទាល់ខ្លួន ដូច្នេះវាអាចដំណើរការទន្ទឹមគ្នាជាមួយនឹងកំណែធម្មតា (stable version)។ វាត្រូវបានបង្កើតឡើងដោយស្វ័យប្រវត្តិពី commit `main` ចុងក្រោយបង្អស់ និងធ្វើបច្ចុប្បន្នភាពដោយស្វ័យប្រវត្តិតាមរយៈ Sparkle feed របស់វាផ្ទាល់។

## ការស្ដារ Session ឡើងវិញ (អាកប្បកិរិយាបច្ចុប្បន្ន)

នៅពេលបើកឡើងវិញ បច្ចុប្បន្ន cmux នឹងស្ដារតែប្លង់កម្មវិធី និងទិន្នន័យមេតា (metadata) ប៉ុណ្ណោះ៖

* ប្លង់ Window/workspace/pane
* ថតការងារ (Working directories)
* Terminal scrollback (ប្រឹងប្រែងឱ្យអស់លទ្ធភាព)
* ប្រវត្តិរុករក និង URL របស់កម្មវិធីរុករក

cmux **មិន** ស្ដារស្ថានភាពដំណើរការផ្ទាល់ (live process state) នៅក្នុងកម្មវិធី terminal ឡើយ។ ឧទាហរណ៍ session របស់ Claude Code/tmux/vim ដែលកំពុងដំណើរការ មិនទាន់អាចបន្តឡើងវិញបានទេបន្ទាប់ពីចាប់ផ្ដើមឡើងវិញ។

## Star History

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## ការចូលរួមចំណែក (Contributing)

វិធីក្នុងការចូលរួម៖

* តាមដានពួកយើងនៅលើ X សម្រាប់ការធ្វើបច្ចុប្បន្នភាពនានា [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), និង [@austinywang](https://x.com/austinywang)
* ចូលរួមការសន្ទនានៅលើ [Discord](https://discord.gg/xsgFEVrWCZ)
* បង្កើត និងចូលរួមក្នុង [GitHub issues](https://github.com/manaflow-ai/cmux/issues) និង [discussions](https://github.com/manaflow-ai/cmux/discussions)
* ប្រាប់ពួកយើងអំពីអ្វីដែលអ្នកកំពុងបង្កើតជាមួយ cmux

## សហគមន៍ (Community)

* [Discord](https://discord.gg/xsgFEVrWCZ)
* [GitHub](https://github.com/manaflow-ai/cmux)
* [X / Twitter](https://twitter.com/manaflowai)
* [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
* [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
* [Reddit](https://www.reddit.com/r/cmux/)

## កំណែអ្នកស្ថាបនិក (Founder's Edition)

cmux គឺឥតគិតថ្លៃ ជាកូដបើកចំហ (open source) និងតែងតែបែបនេះជារៀងរហូត។ ប្រសិនបើអ្នកចង់គាំទ្រដល់ការអភិវឌ្ឍន៍ និងទទួលបានសិទ្ធិប្រើប្រាស់មុខងារថ្មីៗមុនគេ (early access)៖

[**ទទួលបានកំណែអ្នកស្ថាបនិក (Get Founder's Edition)**](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)

* **ការស្នើសុំមុខងារ/ការជួសជុលកំហុសត្រូវបានផ្តល់អាទិភាព**
* **សិទ្ធិប្រើប្រាស់មុនគេ៖ cmux AI ដែលផ្តល់ឱ្យអ្នកនូវបរិបទ (context) លើរាល់ workspace, tab និង panel**
* **សិទ្ធិប្រើប្រាស់មុនគេ៖ កម្មវិធី iOS ដែលមាន terminal ធ្វើសមកាលកម្ម (synced) រវាងកុំព្យូទ័រ និងទូរស័ព្ទ**
* **សិទ្ធិប្រើប្រាស់មុនគេ៖ Cloud VMs**
* **សិទ្ធិប្រើប្រាស់មុនគេ៖ មុខងារសំឡេង (Voice mode)**
* **iMessage/WhatsApp ផ្ទាល់ខ្លួនរបស់ខ្ញុំ**

## អាជ្ញាប័ណ្ណ (License)

គម្រោងនេះត្រូវបានផ្តល់អាជ្ញាប័ណ្ណក្រោម GNU Affero General Public License v3.0 ឬក្រោយនេះ (`AGPL-3.0-or-later`)។

សូមមើលឯកសារ `LICENSE` សម្រាប់អត្ថបទពេញលេញ។
