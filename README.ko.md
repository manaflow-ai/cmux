> 이 문서는 Claude가 번역했어요. 개선할 부분이 있다면 PR을 보내주세요.

<h1 align="center">cmux</h1>
<p align="center">세로 탭과 알림을 지원하는 AI 코딩 에이전트용 Ghostty 기반 macOS 터미널</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="macOS용 cmux 다운로드" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | 한국어 | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux 스크린샷" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ 데모 영상</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## 기능

<table>
<tr>
<td width="40%" valign="middle">
<h3>알림 링</h3>
코딩 에이전트가 입력을 기다리면 패널에 파란색 링이 뜨고 탭이 강조돼요
</td>
<td width="60%">
<img src="./docs/assets/ko/notification-rings.png" alt="알림 링" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>알림 패널</h3>
대기 중인 알림을 한곳에서 확인하고, 가장 최근 읽지 않은 알림으로 바로 이동할 수 있어요
</td>
<td width="60%">
<img src="./docs/assets/ko/sidebar-notification-badge.png" alt="사이드바 알림 배지" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>내장 브라우저</h3>
<a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>에서 포팅된 스크립팅 API를 갖춘 브라우저를 터미널 옆에 띄울 수 있어요
</td>
<td width="60%">
<img src="./docs/assets/ko/built-in-browser.png" alt="내장 브라우저" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>세로 + 가로 탭</h3>
사이드바에서 git 브랜치, 연결된 PR 상태/번호, 작업 디렉토리, 수신 포트, 최근 알림 텍스트를 한눈에 볼 수 있어요. 수평·수직 분할을 지원해요.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="세로 탭과 분할 패널" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code>로 원격 머신용 워크스페이스를 생성해요. 브라우저 패널은 원격 네트워크를 통해 라우팅되어 localhost가 그대로 작동해요. 원격 세션에 이미지를 드래그하면 scp로 업로드돼요.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code>로 Claude Code의 팀원 모드를 한 명령어로 실행해요. 팀원은 네이티브 분할로 생성되며 사이드바에 메타데이터와 알림이 표시돼요. tmux가 필요 없어요.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **브라우저 가져오기** — Chrome, Firefox, Arc 및 20개 이상의 브라우저에서 쿠키, 방문 기록, 세션을 가져와서 브라우저 패널이 로그인된 상태로 시작돼요
- **커스텀 명령어** — [`cmux.json`](https://cmux.com/docs/custom-commands)에서 프로젝트별 액션을 정의하고 명령 팔레트에서 실행할 수 있어요
- **스크립팅** — CLI와 socket API로 워크스페이스 생성, 패널 분할, 키 입력 전송, 브라우저 자동화가 가능해요
- **네이티브 macOS 앱** — Electron이 아닌 Swift와 AppKit으로 만들었어요. 빠르게 실행되고 메모리도 적게 써요.
- **Ghostty 호환** — 기존 `~/.config/ghostty/config`에서 테마, 글꼴, 색상 설정을 그대로 읽어와요
- **GPU 가속** — libghostty 기반이라 렌더링이 부드러워요
- **키보드 단축키** — 워크스페이스, 분할, 브라우저 등을 위한 [풍부한 단축키](https://cmux.com/docs/keyboard-shortcuts)를 제공해요
- **오픈 소스** — 무료이고 GPL 라이선스예요

## 설치하기

### DMG (권장)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="macOS용 cmux 다운로드" width="180" />
</a>

`.dmg` 파일을 열고 cmux를 응용 프로그램 폴더로 드래그하면 돼요. Sparkle을 통해 자동 업데이트되니 한 번만 다운로드하면 돼요.

### Homebrew

```bash
brew install --cask cmux
```

나중에 업데이트하려면 아래 명령어를 실행해주세요:

```bash
brew upgrade --cask cmux
```

처음 실행할 때 macOS에서 개발자 확인 팝업이 뜰 수 있어요. **열기**를 클릭하면 돼요.

## 왜 cmux를 만들었나요?

저는 Claude Code와 Codex 세션을 여러 개 동시에 돌려요. 예전에는 Ghostty에서 분할 패널을 여러 개 열어놓고, 에이전트가 입력을 기다릴 때 macOS 기본 알림에 의존했어요. 그런데 Claude Code 알림은 항상 "Claude is waiting for your input"이라는 아무 맥락 없이 똑같은 메시지뿐이었고, 탭이 많아지면 제목조차 읽을 수가 없었어요.

여러 코딩 오케스트레이터를 써봤는데, 대부분 Electron/Tauri 앱이라 성능이 별로였어요. GUI 오케스트레이터는 특정 워크플로우에 갇히게 돼서 터미널이 더 낫다고 생각했고요. 그래서 Swift/AppKit으로 네이티브 macOS 앱인 cmux를 직접 만들었어요. 터미널 렌더링에는 libghostty를 쓰고, 기존 Ghostty 설정에서 테마, 글꼴, 색상을 그대로 가져와요.

핵심은 사이드바와 알림 시스템이에요. 사이드바에는 각 워크스페이스의 git 브랜치, 연결된 PR 상태/번호, 작업 디렉토리, 수신 포트, 최근 알림 텍스트를 보여주는 세로 탭이 있어요. 알림 시스템은 터미널 시퀀스(OSC 9/99/777)를 감지하고, Claude Code나 OpenCode 같은 에이전트 훅에 연결할 수 있는 CLI(`cmux notify`)를 제공해요. 에이전트가 대기 중이면 해당 패널에 파란색 링이 뜨고 사이드바 탭이 강조되니까, 여러 패널과 탭 중에서 어디서 입력을 기다리는지 바로 알 수 있어요. ⌘⇧U를 누르면 가장 최근 읽지 않은 알림으로 이동해요.

내장 브라우저는 [agent-browser](https://github.com/vercel-labs/agent-browser)에서 포팅한 스크립팅 API를 제공해요. 에이전트가 접근성 트리 스냅샷을 가져오고, 요소를 참조·클릭하고, 양식을 채우고, JS를 실행할 수 있어요. 터미널 옆에 브라우저 패널을 띄워서 Claude Code가 개발 서버와 직접 상호작용하게 할 수 있어요.

CLI와 socket API로 모든 걸 자동화할 수 있어요 — 워크스페이스/탭 생성, 패널 분할, 키 입력 전송, 브라우저에서 URL 열기까지요.

## The Zen of cmux

cmux는 개발자가 도구를 어떻게 사용해야 하는지 규정하지 않아요. 터미널과 브라우저에 CLI가 있고, 나머지는 여러분의 몫이에요.

cmux는 솔루션이 아니라 프리미티브예요. 터미널, 브라우저, 알림, 워크스페이스, 분할, 탭, 그리고 이 모든 것을 제어하는 CLI를 제공해요. cmux는 코딩 에이전트를 특정 방식으로 사용하도록 강요하지 않아요. 프리미티브로 무엇을 만들지는 여러분에게 달려 있어요.

최고의 개발자들은 항상 자신만의 도구를 만들어왔어요. 에이전트와 함께 일하는 최적의 방법은 아직 아무도 찾지 못했고, 폐쇄적인 제품을 만드는 팀들도 마찬가지예요. 자신의 코드베이스에 가장 가까운 개발자가 먼저 답을 찾을 거예요.

100만 명의 개발자에게 조합 가능한 프리미티브를 주면, 어떤 프로덕트 팀이 위에서 설계하는 것보다 빠르게 가장 효율적인 워크플로우를 함께 찾아낼 거예요.

## 문서

cmux 설정 방법에 대한 자세한 내용은 [문서를 확인해주세요](https://cmux.com/docs/getting-started?utm_source=readme).

## 키보드 단축키

### 워크스페이스

| 단축키 | 동작 |
|----------|--------|
| ⌘ N | 새 워크스페이스 |
| ⌘ 1–8 | 워크스페이스 1–8로 이동 |
| ⌘ 9 | 마지막 워크스페이스로 이동 |
| ⌃ ⌘ ] | 다음 워크스페이스 |
| ⌃ ⌘ [ | 이전 워크스페이스 |
| ⌘ ⇧ W | 워크스페이스 닫기 |
| ⌘ ⇧ R | 워크스페이스 이름 변경 |
| ⌥ ⌘ E | 워크스페이스 설명 편집 |
| ⌘ B | 사이드바 토글 |
| ⌥ ⌘ B | 오른쪽 사이드바 토글 |
| ⌘ ⇧ E | 오른쪽 사이드바 포커스 토글 |

### 서피스

| 단축키 | 동작 |
|----------|--------|
| ⌘ T | 새 서피스 |
| ⌘ ⇧ ] | 다음 서피스 |
| ⌘ ⇧ [ | 이전 서피스 |
| ⌃ Tab | 다음 서피스 |
| ⌃ ⇧ Tab | 이전 서피스 |
| ⌃ 1–8 | 서피스 1–8로 이동 |
| ⌃ 9 | 마지막 서피스로 이동 |
| ⌘ W | 서피스 닫기 |

### 분할 패널

| 단축키 | 동작 |
|----------|--------|
| ⌘ D | 오른쪽으로 분할 |
| ⌘ ⇧ D | 아래로 분할 |
| ⌥ ⌘ ← → ↑ ↓ | 방향키로 패널 포커스 이동 |
| ⌘ ⇧ H | 현재 패널 깜빡임 |

### 브라우저

브라우저 개발자 도구 단축키는 Safari 기본값을 따르며, `설정 → 키보드 단축키`에서 변경할 수 있어요.
⌃ P를 포함한 명령 팔레트 탐색 단축키도 변경할 수 있으며, 비워두면 키 입력이 활성 터미널로 전달돼요.

| 단축키 | 동작 |
|----------|--------|
| ⌘ ⇧ L | 분할 패널로 브라우저 열기 |
| ⌘ L | 주소창 포커스 |
| ⌘ [ | 뒤로 |
| ⌘ ] | 앞으로 |
| ⌘ R | 페이지 새로고침 |
| ⌥ ⌘ I | 개발자 도구 열기 (Safari 기본값) |
| ⌥ ⌘ C | JavaScript 콘솔 표시 (Safari 기본값) |

### 알림

| 단축키 | 동작 |
|----------|--------|
| ⌘ I | 알림 패널 표시 |
| ⌘ ⇧ U | 최근 읽지 않은 알림으로 이동 |
| ⌥ ⌘ U | 현재 항목의 읽지 않음 상태 토글 |
| ⌃ ⌘ U | 현재 항목을 가장 오래된 읽지 않음으로 표시하고 다음 최신 읽지 않음으로 이동 |

### 찾기

| 단축키 | 동작 |
|----------|--------|
| ⌘ F | 찾기 |
| ⌘ ⇧ F | 디렉토리에서 찾기 |
| ⌘ G / ⌥ ⌘ G | 다음 찾기 / 이전 찾기 |
| ⌥ ⌘ ⇧ F | 찾기 바 숨기기 |
| ⌘ E | 선택한 텍스트로 찾기 |

### 터미널

| 단축키 | 동작 |
|----------|--------|
| ⌘ K | 스크롤백 지우기 |
| ⌘ C | 복사 (선택 시) |
| ⌘ V | 붙여넣기 |
| ⌘ + / ⌘ - | 글꼴 크기 확대 / 축소 |
| ⌘ 0 | 글꼴 크기 초기화 |

### 창

| 단축키 | 동작 |
|----------|--------|
| ⌘ ⇧ N | 새 창 |
| ⌘ ⇧ O | 이전 세션 다시 열기 |
| ⌘ , | 설정 |
| ⌘ ⇧ , | 설정 다시 불러오기 |
| ⌘ Q | 종료 |

## 나이틀리 빌드

[cmux NIGHTLY 다운로드](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY는 자체 번들 ID를 가진 별도의 앱이라 안정 버전과 함께 실행할 수 있어요. 최신 `main` 커밋에서 자동으로 빌드되고, 자체 Sparkle 피드를 통해 자동 업데이트돼요.

나이틀리 버그는 [GitHub Issues](https://github.com/manaflow-ai/cmux/issues)나 [Discord의 #nightly-bugs](https://discord.gg/xsgFEVrWCZ)에서 알려주세요.

## 세션 복원

cmux를 종료하면 현재 세션을 저장합니다. 다시 실행하면 cmux가 앱이 관리하는 상태를 복원합니다:
- 창/워크스페이스/패널 레이아웃
- 작업 디렉토리
- 터미널 스크롤백 (최선 노력)
- 브라우저 URL 및 탐색 기록

cmux는 임의의 라이브 프로세스 상태를 체크포인트하지 않습니다. tmux, vim, shell, 지원되지 않는 터미널 앱은 일반 터미널로 다시 열립니다.

지원되는 에이전트 세션은 hooks가 네이티브 세션 ID를 저장한 경우 다시 시작할 수 있습니다. 에이전트의 바이너리가 `PATH`에 오도록, 에이전트 CLI를 설치한 후에 hooks를 설치하세요:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup`은 찾을 수 있는 지원 에이전트를 설치하고 건너뛴 에이전트에 대한 요약을 출력합니다. 지원되는 resume 통합에는 Claude Code, Codex, Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory, Qoder가 포함됩니다. Claude Code는 설정에서 Claude 통합이 활성화된 경우 cmux의 Claude 래퍼가 처리합니다.

고급 사용자와 통합은 현재 터미널 surface에 사용자 지정 resume 명령을 연결할 수 있습니다. tmux 세션이나 사용자 지정 에이전트 CLI처럼 자체 영구 상태가 있는 도구에 유용합니다:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

이 binding은 cmux surface에 계속 연결됩니다. 공개 CLI나 socket으로 만든 binding은, 자동 복원을 위해 서명된 명령 접두사를 승인하지 않는 한, 확인과 수동 resume용으로 저장됩니다. 승인된 접두사는, 존재하는 경우, 작업 디렉토리와 정확한 환경 변수 값에도 연결됩니다. 승인은 **설정 > 터미널 > Resume Commands**에서 검토하거나 편집할 수 있습니다. cmux는 실행 중인 프로세스에서 감지한 tmux binding이나 사용자가 승인한 접두사처럼 신뢰됨으로 표시한 resume binding만 자동 실행합니다. 토큰, 비밀번호, 시크릿, API 키 같은 민감한 환경 변수 키는 resume binding을 저장하기 전에 제거됩니다.

복원된 에이전트 터미널이 resume 명령을 자동 실행하지 않고 유휴 상태로 유지되게 하려면, **설정 > 터미널 > Resume Agent Sessions on Reopen**을 끄거나 `~/.config/cmux/cmux.json`에 다음을 설정하세요:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

이것은 에이전트의 자동 resume 명령만 비활성화합니다. cmux는 여전히 저장된 레이아웃, 작업 디렉토리, 스크롤백, 브라우저 기록을 복원합니다.

마지막으로 저장된 스냅샷을 수동으로 다시 적용해야 한다면 다음을 사용하세요:
- `파일 > 이전 세션 다시 열기`
- `⌘ ⇧ O`
- `cmux restore-session`

내부적으로 cmux는 `~/Library/Application Support/cmux/` 아래에 버전이 지정된 스냅샷을 기록하고, 에이전트 hooks는 `~/.cmuxterm/` 아래에 세션 매핑을 기록합니다. 복원 시 cmux는 먼저 레이아웃을 재구성한 다음, 자동 에이전트 resume가 활성화된 경우 지원되는 에이전트의 네이티브 resume 명령을 실행합니다.

전체 가이드는 <https://cmux.com/docs/session-restore>에서 읽어보세요.

## FAQ

### cmux는 Ghostty와 어떤 관계인가요?

cmux는 Ghostty의 포크가 아니에요. 앱이 웹 뷰에 WebKit을 사용하는 것과 같은 방식으로, 터미널 렌더링을 위한 라이브러리로 [libghostty](https://github.com/ghostty-org/ghostty)를 사용해요. Ghostty는 독립형 터미널이고, cmux는 그 렌더링 엔진 위에 만든 다른 앱이에요.

### 어떤 플랫폼을 지원하나요?

지금은 macOS만 지원해요. cmux는 네이티브 Swift + AppKit 앱이에요.

### iOS 앱이 있나요?

네, 베타로 있어요. Mobile Connect 창에서 iPhone을 Mac과 페어링하고 휴대폰에서 터미널에 연결할 수 있으며, 터미널 알림 전달도 선택적으로 지원해요. TestFlight에서 cmux BETA로 배포돼요. [iOS 문서](https://cmux.com/docs/ios)를 확인해주세요.

### cmux는 어떤 코딩 에이전트와 함께 작동하나요?

전부 다요. cmux는 터미널이라서, 터미널에서 실행되는 에이전트는 별도 설정 없이 바로 작동해요: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent, 그리고 명령줄에서 실행할 수 있는 무엇이든요.

### cmux로 여러 에이전트와 서브에이전트를 오케스트레이션할 수 있나요?

네. 에이전트가 서브에이전트나 팀원을 생성하면, cmux는 그것들을 숨겨진 백그라운드 프로세스가 아니라 네이티브 패널과 분할로 바꿔요. [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams)와 [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode) 멀티 모델 오케스트레이션을 지원하니, 한 번의 실행에 참여하는 모든 에이전트를 보고 제어할 수 있어요.

### cmux를 원격 머신과 함께 사용할 수 있나요?

네. SSH로 워크스페이스를 열고 원격 tmux 세션에 연결할 수 있어서, 에이전트는 원격 호스트에서 실행하면서 cmux에서 조작할 수 있어요. [SSH 및 원격](https://cmux.com/docs/ssh)을 확인해주세요.

### 알림은 어떻게 작동하나요?

프로세스가 주의를 필요로 하면, cmux는 패널 주변의 알림 링, 사이드바의 읽지 않음 배지, 알림 팝오버, macOS 데스크톱 알림을 표시해요. 이것들은 표준 터미널 이스케이프 시퀀스(OSC 9/99/777)를 통해 자동으로 발생하거나, [cmux CLI](https://cmux.com/docs/notifications#cli-usage)와 [에이전트 훅](https://cmux.com/docs/notifications#integration-examples)으로 직접 트리거할 수 있어요. Claude Code, Codex, OpenCode, pi를 포함해 훅이나 OSC를 지원하는 에이전트는 무엇이든 작동해요.

### cmux는 프로그래밍할 수 있나요?

네. 모든 동작이 cmux CLI와 Unix socket을 통해 제공돼요: 워크스페이스 생성, 분할 패널 열기, 입력 전송, 화면 내용 읽기, 스크린샷 캡처, 그리고 내장 브라우저 제어까지요. [CLI 레퍼런스](https://cmux.com/docs/api)와 [브라우저 자동화](https://cmux.com/docs/browser-automation) 문서를 확인해주세요.

### 내장 브라우저로 무엇을 할 수 있나요?

cmux는 터미널 옆에 진짜 브라우저 패널을 분할할 수 있고, 완전히 프로그래밍할 수 있어요: 탐색, DOM 스냅샷, 클릭, 입력, JavaScript 실행, 그리고 같은 socket API로 콘솔과 네트워크 활동 읽기까지요. 에이전트는 이것을 사용해 cmux를 떠나지 않고 자신의 웹 변경 사항을 검증해요. [브라우저 자동화](https://cmux.com/docs/browser-automation)를 확인해주세요.

### cmux에 스킬이 있나요?

네. 스킬은 CLI 제어, 워크스페이스 자동화, 설정, 브라우저 surface 같은 작업을 위해 cmux에서 실행되는 어떤 에이전트에든 줄 수 있는 재사용 가능한 워크플로우예요. 오픈 컬렉션은 [cmux-skills](https://github.com/manaflow-ai/cmux-skills)에서 둘러보거나 [스킬 문서](https://cmux.com/docs/skills)를 읽어보세요.

### 키보드 단축키를 변경할 수 있나요?

터미널 키바인딩은 Ghostty 설정 파일(`~/.config/ghostty/config`)에서 읽어와요. cmux 전용 단축키(워크스페이스, 분할, 브라우저, 알림)는 설정에서 변경할 수 있어요. 전체 목록은 [기본 단축키](https://cmux.com/docs/keyboard-shortcuts)를 확인해주세요.

### cmux를 커스터마이즈할 수 있나요?

네. 터미널 렌더링은 Ghostty 설정을 사용하니 테마, 글꼴, 색상, 커서가 그대로 넘어와요. `~/.config/cmux/cmux.json`에 있는 cmux 자체 설정으로 사이드바, 탭 바, 분할 패널, 동작을 제어할 수 있고, 모든 [키보드 단축키](https://cmux.com/docs/keyboard-shortcuts)를 편집할 수 있어요. [구성](https://cmux.com/docs/configuration)을 확인해주세요.

### 제 세션이 저장되나요?

네. cmux는 다시 실행할 때 창, 워크스페이스, 패널, 작업 디렉토리, 스크롤백을 복원하고, 이 상태는 앱을 종료한 것뿐만 아니라 컴퓨터를 완전히 재시작해도 유지돼요. Claude Code, Codex, OpenCode 같은 에이전트 세션도 다시 돌아와요. [세션 복원](https://cmux.com/docs/session-restore)을 확인해주세요.

### tmux와 비교하면 어떤가요?

tmux는 어떤 터미널 안에서든 실행되는 터미널 멀티플렉서예요. cmux는 GUI를 갖춘 네이티브 macOS 앱이에요: 세로 탭, 분할 패널, 임베디드 브라우저, socket API가 모두 내장돼 있고, 설정 파일이나 prefix 키가 필요 없어요. 그래도 많은 사람들이 cmux를 SSH와 tmux와 함께 즐겨 사용하고, cmux는 원격 tmux 세션에 네이티브로 연결할 수 있어요 ([베타](https://cmux.com/docs/remote-tmux)).

### cmux는 무료인가요?

네, cmux는 무료로 사용할 수 있어요. 소스 코드는 [GitHub](https://github.com/manaflow-ai/cmux)에서 볼 수 있어요.

### cmux를 어떻게 지원할 수 있나요?

cmux는 무료이고 오픈 소스이며, 앞으로도 그럴 거예요. 개발을 후원하고 cmux AI, iOS 앱, Cloud VMs를 포함해 다음에 나올 것들에 먼저 접근하고 싶다면, [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition)을 확인해주세요.

### 기능 요청이 있거나 버그를 발견했어요?

꼭 듣고 싶어요. GitHub에서 [issue](https://github.com/manaflow-ai/cmux/issues)나 [pull request](https://github.com/manaflow-ai/cmux/pulls)를 열거나, [이메일을 보내주세요](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

## Star History

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## 기여하기

참여 방법:

- X에서 팔로우해주세요: [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen), [@austinywang](https://x.com/austinywang)
- [Discord](https://discord.gg/xsgFEVrWCZ)에서 대화에 참여해주세요
- [GitHub Issues](https://github.com/manaflow-ai/cmux/issues)와 [토론](https://github.com/manaflow-ai/cmux/discussions)에 참여해주세요
- cmux로 무엇을 만들고 있는지 알려주세요

## 커뮤니티

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Founder's Edition

cmux는 무료이고 오픈 소스이며, 앞으로도 그럴 거예요. 개발을 지원하고 다음에 나올 기능에 먼저 접근하고 싶다면:

**[Founder's Edition 구매하기](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **기능 요청/버그 수정 우선 처리**
- **얼리 액세스: 모든 워크스페이스, 탭, 패널의 컨텍스트를 제공하는 cmux AI**
- **얼리 액세스: 데스크톱과 휴대폰 간 터미널을 동기화하는 iOS 앱**
- **얼리 액세스: 클라우드 VM**
- **얼리 액세스: 음성 모드**
- **저의 개인 iMessage/WhatsApp**

## 라이선스

cmux는 [GPL-3.0-or-later](LICENSE) 하에 오픈 소스예요.

GPL을 준수할 수 없는 조직을 위해 상용 라이선스도 제공돼요. 자세한 내용은 [founders@manaflow.com](mailto:founders@manaflow.com)으로 문의해주세요.
