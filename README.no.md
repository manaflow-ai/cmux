> Denne oversettelsen ble generert av Claude. Hvis du har forslag til forbedringer, send gjerne en PR.

<h1 align="center">cmux</h1>
<p align="center">En Ghostty-basert macOS-terminal med vertikale faner og varsler for AI-kodeagenter</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Last ned cmux for macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | Norsk | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux skjermbilde" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demovideo</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funksjoner

<table>
<tr>
<td width="40%" valign="middle">
<h3>Varselringer</h3>
Paneler får en blå ring og faner lyser opp når kodeagenter trenger oppmerksomheten din
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Varselringer" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Varselpanel</h3>
Se alle ventende varsler på ett sted, hopp til det nyeste uleste
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Varselmerke i sidefeltet" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Innebygd nettleser</h3>
Del en nettleser ved siden av terminalen med et skriptbart API portet fra <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Innebygd nettleser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Vertikale + horisontale faner</h3>
Sidefeltet viser git-gren, tilknyttet PR-status/nummer, arbeidsmappe, lyttende porter og siste varselstekst. Del horisontalt og vertikalt.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertikale faner og delte paneler" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> oppretter et arbeidsområde for en ekstern maskin. Nettleserpaneler rutes gjennom det eksterne nettverket, så localhost bare fungerer. Dra et bilde inn i en ekstern sesjon for å laste opp via scp.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> kjører Claude Codes lagkameratmodus med én kommando. Lagkamerater opprettes som native delinger med metadata i sidefeltet og varsler. Ingen tmux nødvendig.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Nettleserimport** — Importer informasjonskapsler, historikk og sesjoner fra Chrome, Firefox, Arc og 20+ andre nettlesere slik at nettleserpaneler starter autentisert
- **Egendefinerte kommandoer** — Definer prosjektspesifikke handlinger i [`cmux.json`](https://cmux.com/docs/custom-commands) som startes fra kommandopaletten
- **Skriptbar** — CLI og socket API for å opprette arbeidsområder, dele paneler, sende tastetrykk og automatisere nettleseren
- **Nativ macOS-app** — Bygget med Swift og AppKit, ikke Electron. Rask oppstart, lavt minneforbruk.
- **Ghostty-kompatibel** — Leser din eksisterende `~/.config/ghostty/config` for temaer, skrifttyper og farger
- **GPU-akselerert** — Drevet av libghostty for jevn gjengivelse

## Installasjon

### DMG (anbefalt)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Last ned cmux for macOS" width="180" />
</a>

Åpne `.dmg`-filen og dra cmux til Programmer-mappen. cmux oppdaterer seg selv automatisk via Sparkle, så du trenger bare å laste ned én gang.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

For å oppdatere senere:

```bash
brew upgrade --cask cmux
```

Ved første oppstart kan macOS be deg bekrefte åpning av en app fra en identifisert utvikler. Klikk **Åpne** for å fortsette.

## Hvorfor cmux?

Jeg kjører mange Claude Code- og Codex-sesjoner parallelt. Jeg brukte Ghostty med en haug delte paneler, og stolte på native macOS-varsler for å vite når en agent trengte meg. Men Claude Codes varselstekst er alltid bare "Claude is waiting for your input" uten kontekst, og med nok faner åpne kunne jeg ikke engang lese titlene lenger.

Jeg prøvde noen kodeorkestratorer, men de fleste var Electron/Tauri-apper og ytelsen irriterte meg. Jeg foretrekker også terminalen siden GUI-orkestratorer låser deg inn i arbeidsflyten deres. Så jeg bygde cmux som en nativ macOS-app i Swift/AppKit. Den bruker libghostty for terminalgjengivelse og leser din eksisterende Ghostty-konfigurasjon for temaer, skrifttyper og farger.

Hovedtilleggene er sidefeltet og varselsystemet. Sidefeltet har vertikale faner som viser git-gren, tilknyttet PR-status/nummer, arbeidsmappe, lyttende porter og siste varselstekst for hvert arbeidsområde. Varselsystemet fanger opp terminalsekvenser (OSC 9/99/777) og har en CLI (`cmux notify`) du kan koble til agentkroker for Claude Code, OpenCode osv. Når en agent venter, får panelet en blå ring og fanen lyser opp i sidefeltet, så jeg kan se hvilken som trenger meg på tvers av delinger og faner. Cmd+Shift+U hopper til det nyeste uleste.

Den innebygde nettleseren har et skriptbart API portet fra [agent-browser](https://github.com/vercel-labs/agent-browser). Agenter kan ta overblikk over tilgjengelighetstreet, hente elementreferanser, klikke, fylle ut skjemaer og kjøre JS. Du kan dele et nettleserpanel ved siden av terminalen og la Claude Code samhandle med utviklingsserveren din direkte.

Alt er skriptbart gjennom CLI og socket API — opprett arbeidsområder/faner, del paneler, send tastetrykk, åpne URLer i nettleseren.

## The Zen of cmux

cmux er ikke foreskrivende om hvordan utviklere bruker verktøyene sine. Det er en terminal og nettleser med en CLI, og resten er opp til deg.

cmux er en primitiv, ikke en løsning. Det gir deg en terminal, en nettleser, varsler, arbeidsområder, delinger, faner og en CLI for å kontrollere alt sammen. cmux tvinger deg ikke inn i en bestemt måte å bruke kodeagenter på. Hva du bygger med primitivene er ditt.

De beste utviklerne har alltid bygget sine egne verktøy. Ingen har funnet ut den beste måten å jobbe med agenter på ennå, og teamene som bygger lukkede produkter har definitivt ikke gjort det heller. Utviklerne som er nærmest sine egne kodebaser vil finne det ut først.

Gi en million utviklere komponerbare primitiver og de vil kollektivt finne de mest effektive arbeidsflytene raskere enn noe produktteam kunne designet ovenfra og ned.

## Dokumentasjon

For mer informasjon om hvordan du konfigurerer cmux, [gå til dokumentasjonen vår](https://cmux.com/docs/getting-started?utm_source=readme).

## Tastatursnarveier

### Arbeidsområder

| Snarvei | Handling |
|----------|--------|
| ⌘ N | Nytt arbeidsområde |
| ⌘ 1–8 | Hopp til arbeidsområde 1–8 |
| ⌘ 9 | Hopp til siste arbeidsområde |
| ⌃ ⌘ ] | Neste arbeidsområde |
| ⌃ ⌘ [ | Forrige arbeidsområde |
| ⌘ ⇧ W | Lukk arbeidsområde |
| ⌘ ⇧ R | Gi nytt navn til arbeidsområde |
| ⌘ B | Vis/skjul sidefelt |

### Overflater

| Snarvei | Handling |
|----------|--------|
| ⌘ T | Ny overflate |
| ⌘ ⇧ ] | Neste overflate |
| ⌘ ⇧ [ | Forrige overflate |
| ⌃ Tab | Neste overflate |
| ⌃ ⇧ Tab | Forrige overflate |
| ⌃ 1–8 | Hopp til overflate 1–8 |
| ⌃ 9 | Hopp til siste overflate |
| ⌘ W | Lukk overflate |

### Delte paneler

| Snarvei | Handling |
|----------|--------|
| ⌘ D | Del til høyre |
| ⌘ ⇧ D | Del nedover |
| ⌥ ⌘ ← → ↑ ↓ | Fokuser panel i retning |
| ⌘ ⇧ H | Blink fokusert panel |

### Nettleser

Nettleserens utviklerverktøysnarveier følger Safari-standarder og kan tilpasses i `Innstillinger → Tastatursnarveier`.

| Snarvei | Handling |
|----------|--------|
| ⌘ ⇧ L | Åpne nettleser i deling |
| ⌘ L | Fokuser adressefeltet |
| ⌘ [ | Tilbake |
| ⌘ ] | Fremover |
| ⌘ R | Last inn siden på nytt |
| ⌥ ⌘ I | Vis/skjul utviklerverktøy (Safari-standard) |
| ⌥ ⌘ C | Vis JavaScript-konsoll (Safari-standard) |

### Varsler

| Snarvei | Handling |
|----------|--------|
| ⌘ I | Vis varselpanel |
| ⌘ ⇧ U | Hopp til nyeste uleste |

### Søk

| Snarvei | Handling |
|----------|--------|
| ⌘ F | Søk |
| ⌘ G / ⌘ ⇧ G | Søk neste / forrige |
| ⌘ ⇧ F | Skjul søkelinje |
| ⌘ E | Bruk utvalg til søk |

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
| ⌘ ⇧ , | Last inn konfigurasjon på nytt |
| ⌘ Q | Avslutt |

## Nattlige bygg

[Last ned cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY er en separat app med sin egen bundle-ID, så den kjører ved siden av den stabile versjonen. Bygges automatisk fra den siste `main`-commiten og oppdateres automatisk via sin egen Sparkle-feed.

## Sesjonssgjenoppretting (nåværende oppførsel)

Ved omstart gjenoppretter cmux for øyeblikket kun applayouten og metadata:
- Vindu-/arbeidsområde-/panellayout
- Arbeidsmapper
- Terminal-rullingshistorikk (best effort)
- Nettleser-URL og navigasjonshistorikk

cmux gjenoppretter **ikke** aktive prosesstilstander inne i terminalapper. For eksempel blir aktive Claude Code/tmux/vim-sesjoner ikke gjenopptatt etter omstart ennå.

## Stjernehistorikk

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Bidra

Måter å engasjere seg:

- Følg oss på X for oppdateringer [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), og [@austinywang](https://x.com/austinywang)
- Bli med i samtalen på [Discord](https://discord.gg/xsgFEVrWCZ)
- Opprett og delta i [GitHub-issues](https://github.com/manaflow-ai/cmux/issues) og [diskusjoner](https://github.com/manaflow-ai/cmux/discussions)
- Fortell oss hva du bygger med cmux

## Fellesskap

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Grunnleggerutgaven

cmux er gratis, åpen kildekode, og vil alltid være det. Hvis du vil støtte utviklingen og få tidlig tilgang til det som kommer:

**[Få Grunnleggerutgaven](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Prioriterte funksjonsforespørsler/feilrettinger**
- **Tidlig tilgang: cmux AI som gir deg kontekst om hvert arbeidsområde, fane og panel**
- **Tidlig tilgang: iOS-app med terminaler synkronisert mellom desktop og telefon**
- **Tidlig tilgang: Sky-VMer**
- **Tidlig tilgang: Stemmemodus**
- **Min personlige iMessage/WhatsApp**

## Lisens

cmux er åpen kildekode under [GPL-3.0-or-later](LICENSE).

Hvis organisasjonen din ikke kan overholde GPL, er en kommersiell lisens tilgjengelig. Kontakt [founders@manaflow.com](mailto:founders@manaflow.com) for detaljer.
