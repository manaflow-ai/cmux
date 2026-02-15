> Denne oversettelsen ble generert av Claude. Hvis du har forslag til forbedringer, send gjerne en PR.

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | Norsk | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a>
</p>

<h1 align="center">cmux</h1>
<p align="center">En Ghostty-basert macOS-terminal med vertikale faner og varsler for AI-kodeagenter</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Last ned cmux for macOS" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="cmux skjermbilde" width="900" />
</p>

## Funksjoner

- **Vertikale faner** — Sidefeltet viser git-gren, arbeidsmappe, lyttende porter og siste varselstekst
- **Varselringer** — Paneler far en bla ring og faner lyser opp nar AI-agenter (Claude Code, OpenCode) trenger oppmerksomheten din
- **Varselpanel** — Se alle ventende varsler pa ett sted, hopp til det nyeste uleste
- **Delte paneler** — Horisontale og vertikale delinger
- **Innebygd nettleser** — Del en nettleser ved siden av terminalen med et skriptbart API portet fra [agent-browser](https://github.com/vercel-labs/agent-browser)
- **Skriptbar** — CLI og socket API for a opprette arbeidsomrader, dele paneler, sende tastetrykk og automatisere nettleseren
- **Nativ macOS-app** — Bygget med Swift og AppKit, ikke Electron. Rask oppstart, lavt minneforbruk.
- **Ghostty-kompatibel** — Leser din eksisterende `~/.config/ghostty/config` for temaer, skrifttyper og farger
- **GPU-akselerert** — Drevet av libghostty for jevn gjengivelse

## Installasjon

### DMG (anbefalt)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Last ned cmux for macOS" width="180" />
</a>

Apne `.dmg`-filen og dra cmux til Programmer-mappen. cmux oppdaterer seg selv automatisk via Sparkle, sa du trenger bare a laste ned en gang.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

For a oppdatere senere:

```bash
brew upgrade --cask cmux
```

Ved forste oppstart kan macOS be deg bekrefte apning av en app fra en identifisert utvikler. Klikk **Apne** for a fortsette.

## Hvorfor cmux?

Jeg kjorer mange Claude Code- og Codex-sesjoner parallelt. Jeg brukte Ghostty med en haug delte paneler, og stolte pa native macOS-varsler for a vite nar en agent trengte meg. Men Claude Codes varselstekst er alltid bare "Claude is waiting for your input" uten kontekst, og med nok faner apne kunne jeg ikke engang lese titlene lenger.

Jeg provde noen kodeorkestratorer, men de fleste var Electron/Tauri-apper og ytelsen irriterte meg. Jeg foretrekker ogsa terminalen siden GUI-orkestratorer laser deg inn i arbeidsflyten deres. Sa jeg bygde cmux som en nativ macOS-app i Swift/AppKit. Den bruker libghostty for terminalgjengivelse og leser din eksisterende Ghostty-konfigurasjon for temaer, skrifttyper og farger.

Hovedtilleggene er sidefeltet og varselsystemet. Sidefeltet har vertikale faner som viser git-gren, arbeidsmappe, lyttende porter og siste varselstekst for hvert arbeidsomrade. Varselsystemet fanger opp terminalsekvenser (OSC 9/99/777) og har en CLI (`cmux notify`) du kan koble til agentkroker for Claude Code, OpenCode osv. Nar en agent venter, far panelet en bla ring og fanen lyser opp i sidefeltet, sa jeg kan se hvilken som trenger meg pa tvers av delinger og faner. Cmd+Shift+U hopper til det nyeste uleste.

Den innebygde nettleseren har et skriptbart API portet fra [agent-browser](https://github.com/vercel-labs/agent-browser). Agenter kan ta overblikk over tilgjengelighetstreet, hente elementreferanser, klikke, fylle ut skjemaer og kjore JS. Du kan dele et nettleserpanel ved siden av terminalen og la Claude Code samhandle med utviklingsserveren din direkte.

Alt er skriptbart gjennom CLI og socket API — opprett arbeidsomrader/faner, del paneler, send tastetrykk, apne URLer i nettleseren.

## Tastatursnarveier

### Arbeidsomrader

| Snarvei | Handling |
|----------|--------|
| ⌘ N | Nytt arbeidsomrade |
| ⌘ 1–8 | Hopp til arbeidsomrade 1–8 |
| ⌘ 9 | Hopp til siste arbeidsomrade |
| ⌘ ⇧ W | Lukk arbeidsomrade |

### Overflater

| Snarvei | Handling |
|----------|--------|
| ⌘ T | Ny overflate |
| ⌘ ⇧ [ | Forrige overflate |
| ⌃ ⇧ Tab | Forrige overflate |
| ⌃ 1–8 | Hopp til overflate 1–8 |
| ⌃ 9 | Hopp til siste overflate |
| ⌘ W | Lukk overflate |

### Delte paneler

| Snarvei | Handling |
|----------|--------|
| ⌘ D | Del til hoyre |
| ⌘ ⇧ D | Del nedover |
| ⌥ ⌘ ← → ↑ ↓ | Fokuser panel i retning |

### Nettleser

| Snarvei | Handling |
|----------|--------|
| ⌘ ⇧ B | Apne nettleser i deling |
| ⌘ L | Fokuser adressefeltet |
| ⌘ ] | Fremover |
| ⌘ R | Last inn siden pa nytt |
| ⌥ ⌘ I | Apne utviklerverktoy |

### Varsler

| Snarvei | Handling |
|----------|--------|
| ⌘ ⇧ I | Vis varselpanel |
| ⌘ ⇧ U | Hopp til nyeste uleste |

### Sok

| Snarvei | Handling |
|----------|--------|
| ⌘ F | Sok |
| ⌘ G / ⌘ ⇧ G | Sok neste / forrige |
| ⌘ ⇧ F | Skjul sokelinje |
| ⌘ E | Bruk utvalg til sok |

### Terminal

| Snarvei | Handling |
|----------|--------|
| ⌘ K | Tøm rullingshistorikk |
| ⌘ C | Kopier (med utvalg) |
| ⌘ V | Lim inn |
| ⌘ + / ⌘ - | Øk / reduser skriftstørrelse |
| ⌘ 0 | Tilbakestill skriftstørrelse |

### Vindu

| Snarvei | Handling |
|----------|--------|
| ⌘ ⇧ N | Nytt vindu |
| ⌘ , | Innstillinger |
| ⌘ ⇧ R | Last inn konfigurasjon pa nytt |
| ⌘ Q | Avslutt |

## Lisens

Dette prosjektet er lisensiert under GNU Affero General Public License v3.0 eller nyere (`AGPL-3.0-or-later`).

Se `LICENSE` for den fullstendige teksten.
