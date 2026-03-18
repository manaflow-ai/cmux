> Denne oversættelse er genereret af Claude. Har du forslag til forbedringer, er du velkommen til at oprette en PR.

<h1 align="center">cmux</h1>
<p align="center">En Ghostty-baseret macOS-terminal med lodrette faner og notifikationer til AI-kodningsagenter</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Download cmux til macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | Dansk | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux skærmbillede" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demovideo</a> · <a href="https://cmux.dev/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funktioner

<table>
<tr>
<td width="40%" valign="middle">
<h3>Notifikationsringe</h3>
Paneler får en blå ring, og faner lyser op, når kodningsagenter har brug for din opmærksomhed
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Notifikationsringe" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Notifikationspanel</h3>
Se alle ventende notifikationer ét sted, hop til den seneste ulæste
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Notifikationsbadge i sidebjælken" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Indbygget browser</h3>
Del en browser ved siden af din terminal med en scriptbar API porteret fra <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Indbygget browser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Lodrette + vandrette faner</h3>
Sidebjælken viser git-branch, tilknyttet PR-status/nummer, arbejdsmappe, lyttende porte og seneste notifikationstekst. Del vandret og lodret.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Lodrette faner og delte paneler" width="100%" />
</td>
</tr>
</table>

- **Scriptbar** — CLI og socket API til at oprette workspaces, dele paneler, sende tastetryk og automatisere browseren
- **Nativ macOS-app** — Bygget med Swift og AppKit, ikke Electron. Hurtig opstart, lavt hukommelsesforbrug.
- **Ghostty-kompatibel** — Læser din eksisterende `~/.config/ghostty/config` til temaer, skrifttyper og farver
- **GPU-accelereret** — Drevet af libghostty til jævn rendering

## Installation

### DMG (anbefalet)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Download cmux til macOS" width="180" />
</a>

Åbn `.dmg`-filen og træk cmux til din Programmer-mappe. cmux opdaterer sig selv automatisk via Sparkle, så du behøver kun at downloade én gang.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

For at opdatere senere:

```bash
brew upgrade --cask cmux
```

Ved første start kan macOS bede dig om at bekræfte åbning af en app fra en identificeret udvikler. Klik på **Åbn** for at fortsætte.

## Hvorfor cmux?

Jeg kører mange Claude Code- og Codex-sessioner parallelt. Jeg brugte Ghostty med en masse delte paneler og stolede på native macOS-notifikationer til at vide, hvornår en agent havde brug for mig. Men Claude Codes notifikationstekst er altid bare "Claude is waiting for your input" uden kontekst, og med nok åbne faner kunne jeg ikke engang læse titlerne længere.

Jeg prøvede et par kodningsorkestratore, men de fleste var Electron/Tauri-apps, og ydelsen irriterede mig. Jeg foretrækker også bare terminalen, da GUI-orkestratore låser dig ind i deres arbejdsgang. Så jeg byggede cmux som en nativ macOS-app i Swift/AppKit. Den bruger libghostty til terminal-rendering og læser din eksisterende Ghostty-konfiguration til temaer, skrifttyper og farver.

De vigtigste tilføjelser er sidebjælken og notifikationssystemet. Sidebjælken har lodrette faner, der viser git-branch, tilknyttet PR-status/nummer, arbejdsmappe, lyttende porte og den seneste notifikationstekst for hvert workspace. Notifikationssystemet opfanger terminalsekvenser (OSC 9/99/777) og har en CLI (`cmux notify`), du kan koble til agent-hooks for Claude Code, OpenCode osv. Når en agent venter, får dens panel en blå ring, og fanen lyser op i sidebjælken, så jeg kan se, hvilken der har brug for mig på tværs af opdelinger og faner. Cmd+Shift+U hopper til den seneste ulæste.

Den indbyggede browser har en scriptbar API porteret fra [agent-browser](https://github.com/vercel-labs/agent-browser). Agenter kan tage et snapshot af tilgængelighedstræet, få elementreferencer, klikke, udfylde formularer og evaluere JS. Du kan dele et browserpanel ved siden af din terminal og lade Claude Code interagere direkte med din udviklingsserver.

Alt er scriptbart gennem CLI og socket API — opret workspaces/faner, del paneler, send tastetryk, åbn URL'er i browseren.

## The Zen of cmux

cmux foreskriver ikke, hvordan udviklere bruger deres værktøjer. Det er en terminal og browser med en CLI, resten er op til dig.

cmux er en primitiv, ikke en løsning. Det giver dig en terminal, en browser, notifikationer, workspaces, opdelinger, faner og en CLI til at styre det hele. cmux tvinger dig ikke ind i en forudbestemt måde at bruge kodningsagenter på. Hvad du bygger med primitiverne, er dit eget.

De bedste udviklere har altid bygget deres egne værktøjer. Ingen har endnu fundet den bedste måde at arbejde med agenter på, og holdene bag lukkede produkter har heller ikke. De udviklere, der er tættest på deres egne kodebaser, vil finde ud af det først.

Giv en million udviklere komponerbare primitiver, og de vil kollektivt finde de mest effektive arbejdsgange hurtigere, end noget produkthold kunne designe oppefra.

## Dokumentation

For mere information om konfiguration af cmux, [se vores dokumentation](https://cmux.dev/docs/getting-started?utm_source=readme).

## Tastaturgenveje

### Workspaces

| Genvej | Handling |
|----------|--------|
| ⌘ N | Nyt workspace |
| ⌘ 1–8 | Hop til workspace 1–8 |
| ⌘ 9 | Hop til sidste workspace |
| ⌃ ⌘ ] | Næste workspace |
| ⌃ ⌘ [ | Forrige workspace |
| ⌘ ⇧ W | Luk workspace |
| ⌘ ⇧ R | Omdøb workspace |
| ⌘ B | Skjul/vis sidebjælke |

### Overflader

| Genvej | Handling |
|----------|--------|
| ⌘ T | Ny overflade |
| ⌘ ⇧ ] | Næste overflade |
| ⌘ ⇧ [ | Forrige overflade |
| ⌃ Tab | Næste overflade |
| ⌃ ⇧ Tab | Forrige overflade |
| ⌃ 1–8 | Hop til overflade 1–8 |
| ⌃ 9 | Hop til sidste overflade |
| ⌘ W | Luk overflade |

### Delte Paneler

| Genvej | Handling |
|----------|--------|
| ⌘ D | Del til højre |
| ⌘ ⇧ D | Del nedad |
| ⌥ ⌘ ← → ↑ ↓ | Fokuser panel retningsbestemt |
| ⌘ ⇧ H | Blink fokuseret panel |

### Browser

Browserens udviklerværktøjsgenveje følger Safaris standarder og kan tilpasses i `Indstillinger → Tastaturgenveje`.

| Genvej | Handling |
|----------|--------|
| ⌘ ⇧ L | Åbn browser i opdeling |
| ⌘ L | Fokuser adresselinjen |
| ⌘ [ | Tilbage |
| ⌘ ] | Frem |
| ⌘ R | Genindlæs side |
| ⌥ ⌘ I | Slå Udviklerværktøjer til/fra (Safari-standard) |
| ⌥ ⌘ C | Vis JavaScript-konsol (Safari-standard) |

### Notifikationer

| Genvej | Handling |
|----------|--------|
| ⌘ I | Vis notifikationspanel |
| ⌘ ⇧ U | Hop til seneste ulæste |

### Søg

| Genvej | Handling |
|----------|--------|
| ⌘ F | Søg |
| ⌘ G / ⌘ ⇧ G | Find næste / forrige |
| ⌘ ⇧ F | Skjul søgelinje |
| ⌘ E | Brug markering til søgning |

### Terminal

| Genvej | Handling |
|----------|--------|
| ⌘ K | Ryd scrollback |
| ⌘ C | Kopiér (med markering) |
| ⌘ V | Indsæt |
| ⌘ + / ⌘ - | Forøg / formindsk skriftstørrelse |
| ⌘ 0 | Nulstil skriftstørrelse |

### Vindue

| Genvej | Handling |
|----------|--------|
| ⌘ ⇧ N | Nyt vindue |
| ⌘ , | Indstillinger |
| ⌘ ⇧ , | Genindlæs konfiguration |
| ⌘ Q | Afslut |

## Nightly Builds

[Download cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY er en separat app med sit eget bundle-ID, så den kører side om side med den stabile version. Bygges automatisk fra det seneste `main`-commit og opdaterer sig selv automatisk via sit eget Sparkle-feed.

## Sessionsgenoprettelse (nuværende adfærd)

Ved genstart genopretter cmux i øjeblikket kun app-layout og metadata:
- Vindue/workspace/panel-layout
- Arbejdsmapper
- Terminal-scrollback (best effort)
- Browser-URL og navigationshistorik

cmux genopretter **ikke** aktive procestilstande i terminalapps. For eksempel genoptages aktive Claude Code/tmux/vim-sessioner endnu ikke efter genstart.

## Stjernehistorik

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Bidrag

Måder at deltage:

- Følg os på X for opdateringer [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) og [@austinywang](https://x.com/austinywang)
- Deltag i samtalen på [Discord](https://discord.gg/xsgFEVrWCZ)
- Opret og deltag i [GitHub issues](https://github.com/manaflow-ai/cmux/issues) og [diskussioner](https://github.com/manaflow-ai/cmux/discussions)
- Fortæl os, hvad du bygger med cmux

## Fællesskab

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux er gratis, open source og vil altid være det. Hvis du gerne vil støtte udviklingen og få tidlig adgang til det, der kommer:

**[Få Founder's Edition](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Prioriterede funktionsønsker og fejlrettelser**
- **Tidlig adgang: cmux AI der giver dig kontekst om hvert workspace, fane og panel**
- **Tidlig adgang: iOS-app med terminaler synkroniseret mellem desktop og telefon**
- **Tidlig adgang: Cloud VM'er**
- **Tidlig adgang: Stemmetilstand**
- **Min personlige iMessage/WhatsApp**

## Licens

Dette projekt er licenseret under GNU Affero General Public License v3.0 eller senere (`AGPL-3.0-or-later`).

Se `LICENSE` for den fulde tekst.
