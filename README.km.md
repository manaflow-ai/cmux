> ការបកប្រែនេះត្រូវបានបង្កើតដោយ Claude។ ប្រសិនបើអ្នកមានការកែលម្អ សូមបង្កើត PR។

<h1 align="center">cmux</h1>
<p align="center">Terminal សម្រាប់ macOS ផ្អែកលើ Ghostty ដែលមាន tab បញ្ឈរ និងការជូនដំណឹងសម្រាប់ AI coding agents</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Download cmux for macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | ភាសាខ្មែរ | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <strong>WeChat:</strong> ស្កេនកូដ QR ដើម្បីចូលរួមសហគមន៍។<br />
  <img src="./docs/assets/wechat-community-qr.jpg" alt="កូដ QR WeChat សម្រាប់ចូលរួមសហគមន៍ cmux" width="240" />
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux screenshot" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ វីដេអូបង្ហាញពីដំណើរការ (Demo)</a> · <a href="https://cmux.com/blog/zen-of-cmux">ទស្សនវិជ្ជារបស់ cmux (The Zen of cmux)</a>
</p>

## មុខងារ

<table>
<tr>
<td width="40%" valign="middle">
<h3>រង្វង់ការជូនដំណឹង</h3>
ផ្ទាំង (panes) ទទួលបានរង្វង់ពណ៌ខៀវ ហើយផ្ទាំងផ្លាក (tabs) ភ្លឺឡើង នៅពេលភ្នាក់ងារសរសេរកូដ (coding agents) ត្រូវការការយកចិត្តទុកដាក់ពីអ្នក
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Notification rings" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>បន្ទះការជូនដំណឹង</h3>
មើលការជូនដំណឹងដែលកំពុងរង់ចាំទាំងអស់នៅកន្លែងតែមួយ លោតទៅកាន់សារដែលមិនទាន់អានថ្មីបំផុត
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Sidebar notification badge" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>កម្មវិធីរុករកក្នុងកម្មវិធី</h3>
បំបែកកម្មវិធីរុករកនៅជាប់នឹង terminal របស់អ្នក ជាមួយ API ដែលអាចសរសេរ script បាន បានបម្លែងពី <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Built-in browser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>ផ្ទាំងផ្លាកបញ្ឈរ + ផ្តេក</h3>
របារចំហៀង (Sidebar) បង្ហាញ git branch, ស្ថានភាព/លេខ PR ដែលភ្ជាប់, directory កំពុងធ្វើការ, ports ដែលកំពុងស្តាប់, និងអត្ថបទការជូនដំណឹងថ្មីបំផុត។ បំបែកតាមផ្តេក និងបញ្ឈរ។
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertical tabs and split panes" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> បង្កើត workspace សម្រាប់ម៉ាស៊ីនពីចម្ងាយ។ ផ្ទាំងកម្មវិធីរុករកធ្វើដំណើរឆ្លងកាត់បណ្តាញពីចម្ងាយ ដូច្នេះ localhost ដំណើរការបានយ៉ាងស្រួល។ អូសរូបភាពចូលទៅក្នុង session ពីចម្ងាយ ដើម្បីផ្ទុកឡើងតាមរយៈ scp។
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> ដំណើរការ teammate mode របស់ Claude Code ដោយប្រើពាក្យបញ្ជាតែមួយ។ សមាជិកក្រុមកើតឡើងជា splits ដើមកំណើត ជាមួយ metadata របារចំហៀង និងការជូនដំណឹង។ មិនត្រូវការ tmux ឡើយ។
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **ការនាំចូលកម្មវិធីរុករក** — នាំចូល cookies, ប្រវត្តិ, និង sessions ពី Chrome, Firefox, Arc, និងកម្មវិធីរុករកជាង 20 ផ្សេងទៀត ដូច្នេះផ្ទាំងកម្មវិធីរុករកចាប់ផ្តើមដោយបានផ្ទៀងផ្ទាត់រួច
- **ពាក្យបញ្ជាផ្ទាល់ខ្លួន** — កំណត់សកម្មភាពជាក់លាក់តាមគម្រោងនៅក្នុង [`cmux.json`](https://cmux.com/docs/custom-commands) ដែលចាប់ផ្តើមពី command palette
- **អាចសរសេរកម្មវិធីបាន** — CLI និង socket API ដើម្បីបង្កើត workspaces, បំបែកផ្ទាំង, ផ្ញើការវាយបញ្ចូលគ្រាប់ចុច, និងធ្វើស្វ័យប្រវត្តិកម្មកម្មវិធីរុករក
- **កម្មវិធី macOS ដើមកំណើត** — បង្កើតឡើងដោយ Swift និង AppKit មិនមែន Electron ឡើយ។ ចាប់ផ្តើមលឿន ប្រើ memory តិច។
- **ឆបគ្នាជាមួយ Ghostty** — អាន `~/.config/ghostty/config` ដែលមានស្រាប់របស់អ្នក សម្រាប់ themes, fonts, និងពណ៌
- **បង្កើនល្បឿនដោយ GPU** — ដំណើរការដោយ libghostty សម្រាប់ការបង្ហាញរលូន
- **ផ្លូវកាត់គ្រាប់ចុច** — [ផ្លូវកាត់ដ៏ទូលំទូលាយ](https://cmux.com/docs/keyboard-shortcuts) សម្រាប់ workspaces, splits, កម្មវិធីរុករក, និងច្រើនទៀត
- **ប្រភពកូដបើកចំហ** — ឥតគិតថ្លៃ និងមានអាជ្ញាប័ណ្ណ GPL

## ការដំឡើង

### DMG (បានណែនាំ)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Download cmux for macOS" width="180" />
</a>

បើក `.dmg` ហើយអូស cmux ទៅកាន់ថត Applications របស់អ្នក។ cmux ធ្វើបច្ចុប្បន្នភាពដោយស្វ័យប្រវត្តិតាមរយៈ Sparkle ដូច្នេះអ្នកគ្រាន់តែទាញយកម្តងគឺគ្រប់គ្រាន់ហើយ។

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

ដើម្បីធ្វើបច្ចុប្បន្នភាពពេលក្រោយ៖

```bash
brew upgrade --cask cmux
```

នៅពេលបើកលើកដំបូង macOS អាចសុំឱ្យអ្នកបញ្ជាក់ការបើកកម្មវិធីពីអ្នកអភិវឌ្ឍន៍ដែលបានកំណត់អត្តសញ្ញាណ។ ចុច **Open** ដើម្បីបន្ត។

## ហេតុអ្វីបានជា cmux?

ខ្ញុំដំណើរការ Claude Code និង Codex ច្រើនវគ្គស្របគ្នា។ ខ្ញុំធ្លាប់ប្រើ Ghostty ជាមួយផ្ទាំងបំបែកជាច្រើន ហើយពឹងផ្អែកលើការជូនដំណឹងដើមនៃ macOS ដើម្បីដឹងពេលណាដែលភ្នាក់ងារត្រូវការខ្ញុំ។ ប៉ុន្តែខ្លឹមសារនៃការជូនដំណឹងរបស់ Claude Code តែងតែគ្រាន់តែជា "Claude is waiting for your input" ដោយគ្មានបរិបទ ហើយជាមួយផ្ទាំងបើកច្រើនគ្រប់គ្រាន់ ខ្ញុំមិនអាចសូម្បីតែអានចំណងជើងបានទៀតទេ។

ខ្ញុំបានសាកល្បង orchestrator សរសេរកូដមួយចំនួន ប៉ុន្តែភាគច្រើននៃពួកវាជាកម្មវិធី Electron/Tauri ហើយដំណើរការរបស់វាបានធ្វើឲ្យខ្ញុំធុញ។ ខ្ញុំក៏គ្រាន់តែចូលចិត្ត terminal ច្រើនជាង ដោយសារ orchestrator ប្រភេទ GUI ចាក់សោអ្នកនៅក្នុង workflow របស់ពួកវា។ ដូច្នេះខ្ញុំបានបង្កើត cmux ជាកម្មវិធី macOS ដើមនៅក្នុង Swift/AppKit។ វាប្រើ libghostty សម្រាប់ការបង្ហាញ terminal ហើយអាន config Ghostty ដែលមានស្រាប់របស់អ្នកសម្រាប់ theme ពុម្ពអក្សរ និងពណ៌។

ការបន្ថែមសំខាន់ៗគឺ sidebar និងប្រព័ន្ធជូនដំណឹង។ sidebar មានផ្ទាំងបញ្ឈរដែលបង្ហាញ git branch ស្ថានភាព/លេខ PR ដែលភ្ជាប់ ថតធ្វើការ port ដែលកំពុងស្ដាប់ និងអត្ថបទជូនដំណឹងចុងក្រោយបំផុតសម្រាប់ workspace នីមួយៗ។ ប្រព័ន្ធជូនដំណឹងចាប់យកលំដាប់ terminal (OSC 9/99/777) ហើយមាន CLI (`cmux notify`) ដែលអ្នកអាចភ្ជាប់ចូលទៅក្នុង hook របស់ភ្នាក់ងារសម្រាប់ Claude Code, OpenCode ។ល។ នៅពេលភ្នាក់ងារកំពុងរង់ចាំ ផ្ទាំងរបស់វាទទួលបានរង្វង់ពណ៌ខៀវ ហើយផ្ទាំងភ្លឺឡើងនៅក្នុង sidebar ដូច្នេះខ្ញុំអាចប្រាប់ថាមួយណាត្រូវការខ្ញុំ កាត់ឆ្លងផ្ទាំងបំបែក និងផ្ទាំងផ្សេងៗ។ Cmd+Shift+U លោតទៅសារដែលមិនទាន់អានថ្មីបំផុត។

browser ក្នុងកម្មវិធីមាន API ដែលអាចសរសេរ script បានដែលផ្ទេរមកពី [agent-browser](https://github.com/vercel-labs/agent-browser)។ ភ្នាក់ងារអាចថត snapshot នៃ accessibility tree ទទួល ref នៃ element ចុច បំពេញ form និងវាយតម្លៃ JS។ អ្នកអាចបំបែកផ្ទាំង browser នៅជាប់នឹង terminal របស់អ្នក ហើយឲ្យ Claude Code ធ្វើអន្តរកម្មជាមួយ dev server របស់អ្នកដោយផ្ទាល់។

អ្វីៗគ្រប់យ៉ាងអាចសរសេរ script បានតាមរយៈ CLI និង socket API — បង្កើត workspace/ផ្ទាំង បំបែកផ្ទាំង ផ្ញើ keystroke បើក URL នៅក្នុង browser។

## ហ្សិន (Zen) នៃ cmux

cmux មិនកំណត់ច្បាប់អំពីរបៀបដែលអ្នកអភិវឌ្ឍកាន់ឧបករណ៍របស់ពួកគេទេ។ វាជា terminal និង browser ជាមួយ CLI ហើយផ្នែកដែលនៅសល់គឺអាស្រ័យលើអ្នក។

cmux គឺជា primitive មិនមែនជាដំណោះស្រាយទេ។ វាផ្ដល់ឲ្យអ្នកនូវ terminal មួយ browser មួយ ការជូនដំណឹង workspace ការបំបែក ផ្ទាំង និង CLI មួយដើម្បីគ្រប់គ្រងវាទាំងអស់។ cmux មិនបង្ខំអ្នកចូលទៅក្នុងវិធីដែលមានគំនិតផ្ដាច់ការក្នុងការប្រើភ្នាក់ងារសរសេរកូដទេ។ អ្វីដែលអ្នកសាងសង់ជាមួយ primitive គឺជារបស់អ្នក។

អ្នកអភិវឌ្ឍល្អបំផុតតែងតែបានសាងសង់ឧបករណ៍ផ្ទាល់ខ្លួនរបស់ពួកគេ។ គ្មាននរណាម្នាក់បានរកឃើញវិធីល្អបំផុតក្នុងការធ្វើការជាមួយភ្នាក់ងារនៅឡើយទេ ហើយក្រុមដែលកំពុងសាងសង់ផលិតផលបិទជិតក៏ប្រាកដជាមិនបានរកឃើញដែរ។ អ្នកអភិវឌ្ឍដែលជិតស្និទ្ធបំផុតនឹង codebase ផ្ទាល់ខ្លួនរបស់ពួកគេនឹងរកឃើញវាមុនគេ។

ផ្ដល់ឲ្យអ្នកអភិវឌ្ឍមួយលាននាក់នូវ primitive ដែលអាចផ្គុំបាន ហើយពួកគេនឹងរួមគ្នារកឃើញ workflow ដែលមានប្រសិទ្ធភាពបំផុតលឿនជាងក្រុមផលិតផលណាមួយអាចរចនាពីលើចុះក្រោម។

## ឯកសារ

សម្រាប់ព័ត៌មានបន្ថែមអំពីរបៀបកំណត់រចនាសម្ព័ន្ធ cmux [សូមមកកាន់ឯកសាររបស់យើង](https://cmux.com/docs/getting-started?utm_source=readme)។

## ផ្លូវកាត់ក្ដារចុច

### Workspaces

| Shortcut | Action |
|----------|--------|
| ⌘ N | Workspace ថ្មី |
| ⌘ 1–8 | លោតទៅ workspace 1–8 |
| ⌘ 9 | លោតទៅ workspace ចុងក្រោយ |
| ⌃ ⌘ ] | Workspace បន្ទាប់ |
| ⌃ ⌘ [ | Workspace មុន |
| ⌘ ⇧ W | បិទ workspace |
| ⌘ ⇧ R | ប្ដូរឈ្មោះ workspace |
| ⌥ ⌘ E | កែសម្រួលការពិពណ៌នា workspace |
| ⌘ B | បិទ/បើក sidebar |
| ⌥ ⌘ B | បិទ/បើក sidebar ខាងស្ដាំ |
| ⌘ ⇧ E | បិទ/បើកការផ្ដោតលើ sidebar ខាងស្ដាំ |

### Surfaces

| Shortcut | Action |
|----------|--------|
| ⌘ T | Surface ថ្មី |
| ⌘ ⇧ ] | Surface បន្ទាប់ |
| ⌘ ⇧ [ | Surface មុន |
| ⌃ Tab | Surface បន្ទាប់ |
| ⌃ ⇧ Tab | Surface មុន |
| ⌃ 1–8 | លោតទៅ surface 1–8 |
| ⌃ 9 | លោតទៅ surface ចុងក្រោយ |
| ⌘ W | បិទ surface |

### Split Panes

| Shortcut | Action |
|----------|--------|
| ⌘ D | បំបែកទៅស្ដាំ |
| ⌘ ⇧ D | បំបែកចុះក្រោម |
| ⌥ ⌘ ← → ↑ ↓ | ផ្ដោតលើផ្ទាំងតាមទិសដៅ |
| ⌘ ⇧ H | បញ្ចេញពន្លឺផ្ទាំងដែលផ្ដោត |

### Browser

ផ្លូវកាត់ឧបករណ៍អ្នកអភិវឌ្ឍនៃ browser អនុវត្តតាមលំនាំដើមរបស់ Safari ហើយអាចប្ដូរបានក្នុង `Settings → Keyboard Shortcuts`។
ផ្លូវកាត់រុករក command palette រួមទាំង ⌃ P ក៏អាចប្ដូរបានដែរ ហើយអាចសម្អាតបាន ដើម្បីឲ្យការចុចគ្រាប់ចុចទៅដល់ terminal សកម្ម។

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ L | បើក browser ក្នុងការបំបែក |
| ⌘ L | ផ្ដោតលើរបារអាសយដ្ឋាន |
| ⌘ [ | ថយក្រោយ |
| ⌘ ] | ទៅមុខ |
| ⌘ R | ផ្ទុកទំព័រឡើងវិញ |
| ⌥ ⌘ I | បិទ/បើក Developer Tools (លំនាំដើម Safari) |
| ⌥ ⌘ C | បង្ហាញ JavaScript Console (លំនាំដើម Safari) |

### Notifications

| Shortcut | Action |
|----------|--------|
| ⌘ I | បង្ហាញផ្ទាំងជូនដំណឹង |
| ⌘ ⇧ U | លោតទៅសារមិនទាន់អានថ្មីបំផុត |
| ⌥ ⌘ U | បិទ/បើកស្ថានភាពមិនទាន់អាននៃធាតុបច្ចុប្បន្ន |
| ⌃ ⌘ U | សម្គាល់ធាតុបច្ចុប្បន្នជាសារមិនទាន់អានចាស់បំផុត ហើយលោតទៅសារមិនទាន់អានថ្មីបន្ទាប់ |

### Find

| Shortcut | Action |
|----------|--------|
| ⌘ F | ស្វែងរក |
| ⌘ ⇧ F | ស្វែងរកក្នុងថត |
| ⌘ G / ⌥ ⌘ G | ស្វែងរកបន្ទាប់ / មុន |
| ⌥ ⌘ ⇧ F | លាក់របារស្វែងរក |
| ⌘ E | ប្រើការជ្រើសរើសសម្រាប់ស្វែងរក |

### Terminal

| Shortcut | Action |
|----------|--------|
| ⌘ K | សម្អាត scrollback |
| ⌘ C | ចម្លង (ជាមួយការជ្រើសរើស) |
| ⌘ V | បិទភ្ជាប់ |
| ⌘ + / ⌘ - | បង្កើន / បន្ថយទំហំពុម្ពអក្សរ |
| ⌘ 0 | កំណត់ទំហំពុម្ពអក្សរឡើងវិញ |

### Window

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ N | បង្អួចថ្មី |
| ⌘ ⇧ O | បើកវគ្គមុនឡើងវិញ |
| ⌘ , | ការកំណត់ |
| ⌘ ⇧ , | ផ្ទុកការកំណត់រចនាសម្ព័ន្ធឡើងវិញ |
| ⌘ Q | ចាកចេញ |

## ការស្ថាបនាប្រចាំយប់ (Nightly Builds)

[Download cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY គឺជាកម្មវិធីដាច់ដោយឡែកមួយដែលមាន bundle ID ផ្ទាល់របស់វា ដូច្នេះវាដំណើរការទន្ទឹមនឹងកំណែដែលមានស្ថិរភាព។ វាត្រូវបានស្ថាបនាដោយស្វ័យប្រវត្តិពី commit `main` ចុងក្រោយបង្អស់ និងធ្វើបច្ចុប្បន្នភាពដោយស្វ័យប្រវត្តិតាមរយៈ feed Sparkle ផ្ទាល់របស់វា។

រាយការណ៍ពីបញ្ហា nightly នៅលើ [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) ឬនៅក្នុង [#nightly-bugs on Discord](https://discord.gg/xsgFEVrWCZ)។

## ការស្ដារ Session ឡើងវិញ

ការចាកចេញពី cmux រក្សាទុក session បច្ចុប្បន្ន។ នៅពេលបើកដំណើរការឡើងវិញ cmux ស្ដារស្ថានភាពដែលជាកម្មសិទ្ធិរបស់កម្មវិធីឡើងវិញ៖
- ប្លង់ Window/workspace/pane
- ថតធ្វើការ
- Terminal scrollback (តាមការខិតខំល្អបំផុត)
- URL របស់ browser និងប្រវត្តិការរុករក

cmux មិនធ្វើ checkpoint ស្ថានភាពដំណើរការផ្ទាល់ណាមួយតាមអំពើចិត្តទេ។ tmux, vim, shells និងកម្មវិធី terminal ដែលមិនត្រូវបានគាំទ្រ នឹងបើកឡើងវិញជា terminal ធម្មតា។

Session របស់ agent ដែលត្រូវបានគាំទ្រអាចបន្តដំណើរការវិញបាន នៅពេលដែល hooks បានរក្សាទុក session ID ដើមកំណើត។ ដំឡើង hooks បន្ទាប់ពីដំឡើង agent CLI ដើម្បីឱ្យ binary របស់វាស្ថិតនៅលើ `PATH`៖

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` ដំឡើង agent ដែលត្រូវបានគាំទ្រដែលវាអាចរកឃើញ និងបោះពុម្ពសេចក្ដីសង្ខេបសម្រាប់ agent ដែលត្រូវបានរំលង។ ការរួមបញ្ចូលការបន្តដំណើរការវិញ (resume) ដែលត្រូវបានគាំទ្ររួមមាន Claude Code, Codex, Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory និង Qoder។ Claude Code ត្រូវបានដោះស្រាយដោយ cmux Claude wrapper នៅពេលដែលការរួមបញ្ចូល Claude ត្រូវបានបើកនៅក្នុង Settings។

អ្នកប្រើកម្រិតខ្ពស់ និងការរួមបញ្ចូលអាចភ្ជាប់ពាក្យបញ្ជាបន្តដំណើរការវិញ (resume) ផ្ទាល់ខ្លួនទៅ surface terminal បច្ចុប្បន្ន។ វាមានប្រយោជន៍សម្រាប់ឧបករណ៍ដែលមានស្ថានភាពស្ថិតស្ថេរផ្ទាល់ខ្លួន ដូចជា session tmux ឬ agent CLI ផ្ទាល់ខ្លួន៖

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

ការភ្ជាប់នេះនៅតែភ្ជាប់ជាប់នឹង surface របស់ cmux។ ការភ្ជាប់ដែលបង្កើតឡើងតាមរយៈ CLI សាធារណៈ ឬ socket ត្រូវបានរក្សាទុកសម្រាប់ការត្រួតពិនិត្យ និងការស្ដារដោយដៃ លុះត្រាតែអ្នកអនុម័តបុព្វបទពាក្យបញ្ជាដែលបានចុះហត្ថលេខា (signed command prefix) សម្រាប់ការស្ដារដោយស្វ័យប្រវត្តិ។ បុព្វបទដែលបានអនុម័តក៏ត្រូវបានភ្ជាប់ទៅនឹងថតធ្វើការ និងតម្លៃបរិស្ថានពិតប្រាកដផងដែរ នៅពេលដែលមាន។ ត្រួតពិនិត្យ ឬកែសម្រួលការអនុម័តនៅក្នុង **Settings > Terminal > Resume Commands**។ cmux ដំណើរការដោយស្វ័យប្រវត្តិតែការភ្ជាប់ resume ដែលវាសម្គាល់ថាគួរឱ្យទុកចិត្តប៉ុណ្ណោះ ដូចជាការភ្ជាប់ tmux ដែលត្រូវបានរកឃើញពីដំណើរការផ្ទាល់ ឬបុព្វបទដែលអ្នកប្រើបានអនុម័ត។ កូនសោបរិស្ថានរសើបដូចជា tokens, passwords, secrets និង API keys ត្រូវបានលុបចេញមុនពេលការភ្ជាប់ resume ត្រូវបានរក្សាទុក។

ដើម្បីរក្សា terminal របស់ agent ដែលបានស្ដារ ឱ្យនៅទំនេរ ជំនួសឱ្យការដំណើរការពាក្យបញ្ជា resume របស់ពួកវាដោយស្វ័យប្រវត្តិ សូមបិទ **Settings > Terminal > Resume Agent Sessions on Reopen** ឬកំណត់វានៅក្នុង `~/.config/cmux/cmux.json`៖

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

វាបិទតែពាក្យបញ្ជា resume របស់ agent ដោយស្វ័យប្រវត្តិប៉ុណ្ណោះ។ cmux នៅតែស្ដារប្លង់ដែលបានរក្សាទុក ថតធ្វើការ scrollback និងប្រវត្តិ browser ឡើងវិញ។

ប្រសិនបើអ្នកត្រូវការអនុវត្ត snapshot ដែលបានរក្សាទុកចុងក្រោយឡើងវិញដោយដៃ សូមប្រើ៖
- `File > Reopen Previous Session`
- `⌘ ⇧ O`
- `cmux restore-session`

នៅពីក្រោយឆាក cmux សរសេរ snapshot ដែលមានកំណែ នៅក្រោម `~/Library/Application Support/cmux/` ហើយ agent hooks សរសេរ session mappings នៅក្រោម `~/.cmuxterm/`។ នៅពេលស្ដារ cmux កសាងប្លង់ឡើងវិញជាមុនសិន បន្ទាប់មកដំណើរការពាក្យបញ្ជា resume ដើមកំណើតរបស់ agent ដែលត្រូវបានគាំទ្រ នៅពេលដែលការ resume agent ដោយស្វ័យប្រវត្តិត្រូវបានបើក។

អានការណែនាំពេញលេញនៅ <https://cmux.com/docs/session-restore>។

## សំណួរ​ដែល​សួរ​ញឹកញាប់

### តើ cmux ទាក់ទង​នឹង Ghostty យ៉ាង​ដូចម្ដេច?

cmux មិន​មែន​ជា fork របស់ Ghostty ទេ។ វា​ប្រើ [libghostty](https://github.com/ghostty-org/ghostty) ជា library សម្រាប់​ការ​បង្ហាញ​ terminal ដូចគ្នា​នឹង​របៀប​ដែល​កម្មវិធី​ផ្សេងៗ​ប្រើ WebKit សម្រាប់ web views។ Ghostty គឺ​ជា terminal ឯករាជ្យ​មួយ ឯ cmux គឺ​ជា​កម្មវិធី​ផ្សេង​មួយ​ដែល​សាងសង់​នៅ​លើ engine បង្ហាញ​របស់​វា។

### តើ​វា​គាំទ្រ platform អ្វីខ្លះ?

បច្ចុប្បន្ន​មាន​តែ macOS ប៉ុណ្ណោះ។ cmux គឺ​ជា​កម្មវិធី native Swift + AppKit។

### តើ​មាន​កម្មវិធី iOS ដែរ​ឬ​ទេ?

មាន ប៉ុន្តែ​នៅ​ក្នុង​ដំណាក់​កាល beta។ ផ្គូផ្គង iPhone របស់​អ្នក​ជាមួយ Mac របស់​អ្នក​ពី​បង្អួច Mobile Connect រួច​ភ្ជាប់​ទៅ terminals របស់​អ្នក​ពី​ទូរស័ព្ទ​របស់​អ្នក ដោយ​មាន​ជម្រើស​បញ្ជូន​បន្ត​ការ​ជូន​ដំណឹង​របស់ terminal។ វា​ត្រូវ​បាន​ផ្ដល់​ជូន​នៅ​លើ TestFlight ជា cmux BETA។ សូម​មើល [ឯកសារ iOS](https://cmux.com/docs/ios)។

### តើ cmux ដំណើរ​ការ​ជាមួយ coding agents អ្វីខ្លះ?

ទាំងអស់។ cmux គឺ​ជា terminal ដូច្នេះ agent ណាមួយ​ដែល​ដំណើរ​ការ​នៅ​ក្នុង terminal ដំណើរ​ការ​បាន​ភ្លាមៗ៖ Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent និង​អ្វី​ផ្សេង​ទៀត​ដែល​អ្នក​អាច​ចាប់​ផ្ដើម​ពី command line។

### តើ cmux អាច​រៀបចំ agents និង subagents ច្រើន​បាន​ឬ​ទេ?

បាន។ នៅ​ពេល​ដែល agent មួយ​បង្កើត subagents ឬ​សមាជិក​ក្រុម cmux បំប្លែង​ពួក​វា​ទៅ​ជា native panes និង splits ជំនួស​ឱ្យ​ដំណើរ​ការ​ផ្ទៃ​ខាង​ក្រោយ​ដែល​លាក់​បាំង។ វា​គាំទ្រ [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) និង​ការ​រៀបចំ​ multi-model របស់ [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) ដូច្នេះ agent ទាំងអស់​នៅ​ក្នុង​ការ​ដំណើរ​ការ​មួយ​អាច​មើល​ឃើញ​និង​គ្រប់​គ្រង​បាន។

### តើ​ខ្ញុំ​អាច​ប្រើ cmux ជាមួយ​ម៉ាស៊ីន​ពី​ចម្ងាយ​បាន​ឬ​ទេ?

បាន។ បើក workspaces តាម​រយៈ SSH ហើយ​ភ្ជាប់​ទៅ​សម័យ tmux ពី​ចម្ងាយ ដូច្នេះ agents អាច​ដំណើរ​ការ​នៅ​លើ​ម៉ាស៊ីន​ពី​ចម្ងាយ​ខណៈ​ដែល​អ្នក​បញ្ជា​ពួក​វា​ពី cmux។ សូម​មើល [SSH និង​ពី​ចម្ងាយ](https://cmux.com/docs/ssh)។

### តើ​ការ​ជូន​ដំណឹង​ដំណើរ​ការ​យ៉ាង​ដូចម្ដេច?

នៅ​ពេល​ដែល​ដំណើរ​ការ​មួយ​ត្រូវ​ការ​ការ​យក​ចិត្ត​ទុក​ដាក់ cmux បង្ហាញ​រង្វង់​ជូន​ដំណឹង​ជុំ​វិញ panes ស្លាក​មិន​ទាន់​អាន​នៅ​ក្នុង sidebar popover ជូន​ដំណឹង និង​ការ​ជូន​ដំណឹង desktop macOS។ ការ​ទាំង​នេះ​បញ្ចេញ​ដោយ​ស្វ័យ​ប្រវត្តិ​តាម​រយៈ escape sequences ស្ដង់ដារ​របស់ terminal (OSC 9/99/777) ឬ​អ្នក​អាច​ធ្វើ​ឱ្យ​ពួក​វា​ដំណើរ​ការ​ជាមួយ [cmux CLI](https://cmux.com/docs/notifications#cli-usage) និង [agent hooks](https://cmux.com/docs/notifications#integration-examples)។ agent ណាមួយ​ដែល​គាំទ្រ hooks ឬ OSC ដំណើរ​ការ​បាន រួម​ទាំង Claude Code, Codex, OpenCode និង pi។

### តើ cmux អាច​សរសេរ​កម្មវិធី​បាន​ឬ​ទេ?

បាន។ រាល់​សកម្មភាព​ទាំងអស់​មាន​តាម​រយៈ cmux CLI និង Unix socket មួយ៖ បង្កើត workspaces បើក split panes ផ្ញើ input អាន​មាតិកា​អេក្រង់ ថត​រូប​អេក្រង់ និង​បញ្ជា​ browser ក្នុង​កម្មវិធី។ សូម​មើល [ឯកសារ​យោង CLI](https://cmux.com/docs/api) និង​ឯកសារ [browser automation](https://cmux.com/docs/browser-automation)។

### តើ browser ដែល​មាន​ស្រាប់​អាច​ធ្វើ​អ្វី​បាន​ខ្លះ?

cmux អាច​ បំបែក​ browser pane ពិត​ប្រាកដ​មួយ​នៅ​ជាប់​នឹង terminal របស់​អ្នក ហើយ​វា​អាច​សរសេរ​កម្មវិធី​បាន​ពេញលេញ៖ រុករក ថត snapshot នៃ DOM ចុច វាយ​អក្សរ វាយ​តម្លៃ JavaScript និង​អាន console និង​សកម្មភាព network តាម​រយៈ socket API ដូចគ្នា។ agents ប្រើ​វា​ដើម្បី​ផ្ទៀង​ផ្ទាត់​ការ​ផ្លាស់​ប្ដូរ web ផ្ទាល់​ខ្លួន​របស់​ពួក​វា​ដោយ​មិន​ចាំ​បាច់​ចេញ​ពី cmux។ សូម​មើល [browser automation](https://cmux.com/docs/browser-automation)។

### តើ cmux មាន skills ឬ​ទេ?

មាន។ Skills គឺ​ជា workflows ដែល​អាច​ប្រើ​ឡើង​វិញ​ដែល​អ្នក​អាច​ផ្ដល់​ឱ្យ agent ណាមួយ​ដែល​ដំណើរ​ការ​នៅ​ក្នុង cmux សម្រាប់​ការងារ​ដូច​ជា​ការ​បញ្ជា CLI ការ​ស្វ័យ​ប្រវត្តិ​កម្ម workspace ការ​កំណត់ និង browser surfaces។ រុករក​ការ​ប្រមូល​ផ្ដុំ​ដែល​បើក​ចំហ​នៅ [cmux-skills](https://github.com/manaflow-ai/cmux-skills) ឬ​អាន [ឯកសារ skills](https://cmux.com/docs/skills)។

### តើ​ខ្ញុំ​អាច​កែ​សម្រួល keyboard shortcuts បាន​ឬ​ទេ?

keybindings របស់ terminal ត្រូវ​បាន​អាន​ពី​ឯកសារ config របស់ Ghostty (`~/.config/ghostty/config`)។ shortcuts ជាក់​លាក់​របស់ cmux (workspaces, splits, browser, notifications) អាច​កែ​សម្រួល​បាន​នៅ​ក្នុង Settings។ សូម​មើល [shortcuts លំនាំ​ដើម](https://cmux.com/docs/keyboard-shortcuts) សម្រាប់​បញ្ជី​ពេញលេញ។

### តើ​ខ្ញុំ​អាច​កែ​សម្រួល cmux បាន​ឬ​ទេ?

បាន។ ការ​បង្ហាញ terminal ប្រើ config របស់ Ghostty របស់​អ្នក ដូច្នេះ themes, fonts, ពណ៌ និង cursor ត្រូវ​បាន​បន្ត​ដោយ​ផ្ទាល់។ ការ​កំណត់​ផ្ទាល់​ខ្លួន​របស់ cmux នៅ​ក្នុង `~/.config/cmux/cmux.json` គ្រប់​គ្រង sidebar, tab bar, split panes និង​ឥរិយាបថ ហើយ​រាល់ [keyboard shortcut](https://cmux.com/docs/keyboard-shortcuts) អាច​កែ​សម្រួល​បាន។ សូម​មើល [configuration](https://cmux.com/docs/configuration)។

### តើ​សម័យ​របស់​ខ្ញុំ​ត្រូវ​បាន​រក្សា​ទុក​ឬ​ទេ?

រក្សា​ទុក។ cmux ស្ដារ បង្អួច workspaces panes ថត​ការងារ និង scrollback របស់​អ្នក​នៅ​ពេល​អ្នក​បើក​ឡើង​វិញ ហើយ​ស្ថានភាព​នៅ​រស់​រាន​បន្ទាប់​ពី​ការ​បើក​កុំព្យូទ័រ​ឡើង​វិញ​ពេញលេញ មិន​មែន​គ្រាន់​តែ​ការ​បិទ​កម្មវិធី​ប៉ុណ្ណោះ​ទេ។ សម័យ agent ដូច​ជា Claude Code, Codex និង OpenCode ត្រឡប់​មក​វិញ​ផង​ដែរ។ សូម​មើល [session restore](https://cmux.com/docs/session-restore)។

### តើ​វា​ប្រៀប​ធៀប​នឹង tmux យ៉ាង​ដូចម្ដេច?

tmux គឺ​ជា terminal multiplexer ដែល​ដំណើរ​ការ​នៅ​ក្នុង terminal ណាមួយ។ cmux គឺ​ជា​កម្មវិធី native macOS ដែល​មាន GUI៖ vertical tabs, split panes, browser ដែល​បង្កប់ និង socket API ទាំងអស់​មាន​ស្រាប់ ដោយ​មិន​ចាំ​បាច់​មាន​ឯកសារ config ឬ prefix keys។ ទោះ​ជា​យ៉ាង​ណា​ក៏​ដោយ មនុស្ស​ជា​ច្រើន​ដំណើរ​ការ cmux ជាមួយ SSH និង tmux រួម​គ្នា​ដោយ​សប្បាយ​រីករាយ ហើយ cmux អាច​ភ្ជាប់​ទៅ​សម័យ tmux ពី​ចម្ងាយ​របស់​អ្នក​ដោយ native ([beta](https://cmux.com/docs/remote-tmux))។

### តើ cmux ឥត​គិត​ថ្លៃ​ឬ​ទេ?

មែន cmux ឥត​គិត​ថ្លៃ​ក្នុង​ការ​ប្រើ​ប្រាស់។ កូដ​ប្រភព​មាន​នៅ​លើ [GitHub](https://github.com/manaflow-ai/cmux)។

### តើ​ខ្ញុំ​អាច​គាំទ្រ cmux យ៉ាង​ដូចម្ដេច?

cmux ឥត​គិត​ថ្លៃ​និង open source ហើយ​នឹង​នៅ​តែ​បែប​នេះ​ជានិច្ច។ ប្រសិន​បើ​អ្នក​ចង់​គាំទ្រ​ការ​អភិវឌ្ឍ​និង​ទទួល​បាន​ការ​ចូល​ដំណើរ​ការ​មុន​គេ​ចំពោះ​អ្វី​ដែល​នឹង​មក​ដល់ រួម​ទាំង cmux AI, កម្មវិធី iOS និង Cloud VMs សូម​មើល [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition)។

### ខ្ញុំ​មាន​សំណើ​មុខងារ ឬ​រក​ឃើញ​កំហុស?

យើង​ចង់​ស្ដាប់​វា។ បើក [issue](https://github.com/manaflow-ai/cmux/issues) ឬ [pull request](https://github.com/manaflow-ai/cmux/pulls) នៅ​លើ GitHub ឬ [អ៊ីមែល​មក​យើង](mailto:founders@manaflow.com?subject=cmux%20feature%20request)។

## ប្រវត្តិ Star

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## ការចូលរួមចំណែក

មធ្យោបាយដើម្បីចូលរួម៖

- តាមដានពួកយើងនៅលើ X សម្រាប់ព័ត៌មានថ្មីៗ [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), និង [@austinywang](https://x.com/austinywang)
- ចូលរួមការសន្ទនានៅលើ [Discord](https://discord.gg/xsgFEVrWCZ)
- បង្កើត និងចូលរួមនៅក្នុង [GitHub issues](https://github.com/manaflow-ai/cmux/issues) និង [discussions](https://github.com/manaflow-ai/cmux/discussions)
- ប្រាប់ពួកយើងពីអ្វីដែលអ្នកកំពុងបង្កើតជាមួយ cmux

## សហគមន៍

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux គឺឥតគិតថ្លៃ បើកប្រភពកូដ និងនឹងនៅតែជានិច្ច។ ប្រសិនបើអ្នកចង់គាំទ្រការអភិវឌ្ឍន៍ និងទទួលបានសិទ្ធិចូលប្រើមុនគេចំពោះអ្វីដែលនឹងមកដល់បន្ទាប់៖

**[Get Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **សំណើមុខងារ/ការជួសជុលកំហុសដែលត្រូវផ្តល់អាទិភាព**
- **សិទ្ធិចូលប្រើមុនគេ៖ cmux AI ដែលផ្តល់ឱ្យអ្នកនូវបរិបទនៅលើគ្រប់ workspace, tab និង panel**
- **សិទ្ធិចូលប្រើមុនគេ៖ កម្មវិធី iOS ដែលមាន terminals បានធ្វើសមកាលកម្មរវាងកុំព្យូទ័រ និងទូរស័ព្ទ**
- **សិទ្ធិចូលប្រើមុនគេ៖ Cloud VMs**
- **សិទ្ធិចូលប្រើមុនគេ៖ របៀបសំឡេង (Voice mode)**
- **iMessage/WhatsApp ផ្ទាល់ខ្លួនរបស់ខ្ញុំ**

## អាជ្ញាបណ្ណ

cmux គឺបើកប្រភពកូដក្រោម [GPL-3.0-or-later](LICENSE)។

ប្រសិនបើស្ថាប័នរបស់អ្នកមិនអាចអនុលោមតាម GPL បាន អាជ្ញាបណ្ណពាណិជ្ជកម្មមានផ្តល់ជូន។ សូមទាក់ទង [founders@manaflow.com](mailto:founders@manaflow.com) សម្រាប់ព័ត៌មានលម្អិត។
