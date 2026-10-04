var e={background:`#ffffff`,foreground:`#000000`,ghosttyName:`Apple System Colors Light`,name:`cmux-ghostty-light`,palette:{},selectionBackground:`#abd8ff`,selectionForeground:`#000000`,type:`light`},t={background:`#000000`,foreground:`#ffffff`,ghosttyName:`Apple System Colors`,name:`cmux-ghostty-dark`,palette:{},selectionBackground:`#3f638b`,selectionForeground:`#ffffff`,type:`dark`};function n(n){let r={...e,...n?.themes?.light},i={...t,...n?.themes?.dark};return r.foreground=a(r.foreground,r.background,e.foreground),r.selectionForeground=a(r.selectionForeground,r.selectionBackground,e.selectionForeground),i.foreground=a(i.foreground,i.background,t.foreground),i.selectionForeground=a(i.selectionForeground,i.selectionBackground,t.selectionForeground),{backgroundOpacity:u(n?.backgroundOpacity),fontFamily:n?.fontFamily??`Menlo`,fontSize:l(n?.fontSize,10),lineHeight:l(n?.lineHeight,20),theme:{light:n?.theme?.light??r.name??`cmux-ghostty-light`,dark:n?.theme?.dark??i.name??`cmux-ghostty-dark`},themes:{light:r,dark:i}}}function r(e){if(!e)return;let t=e.themes?.light??{},n=e.themes?.dark??{},r=document.documentElement.style;r.setProperty(`--cmux-diff-bg-light`,s(t.background,`#ffffff`)),r.setProperty(`--cmux-diff-bg-dark`,s(n.background,`#000000`)),r.setProperty(`--cmux-diff-fg-light`,s(t.foreground,`#000000`)),r.setProperty(`--cmux-diff-fg-dark`,s(n.foreground,`#ffffff`)),r.setProperty(`--cmux-diff-addition-fg-light`,o(t,[`10`,`2`],`#257a3e`)),r.setProperty(`--cmux-diff-addition-fg-dark`,o(n,[`10`,`2`],`#8fd88f`)),r.setProperty(`--cmux-diff-deletion-fg-light`,o(t,[`9`,`1`],`#b42318`)),r.setProperty(`--cmux-diff-deletion-fg-dark`,o(n,[`9`,`1`],`#ff8a80`)),r.setProperty(`--cmux-diff-selection-bg-light`,s(t.selectionBackground,`#abd8ff`)),r.setProperty(`--cmux-diff-selection-bg-dark`,s(n.selectionBackground,`#3f638b`)),r.setProperty(`--cmux-diff-code-font-family`,c(e.fontFamily)),r.setProperty(`--cmux-diff-font-size`,`${l(e.fontSize,10)}px`),r.setProperty(`--cmux-diff-line-height`,`${l(e.lineHeight,20)}px`)}function i(e,t){return`transparent`}function a(e,t,n){let r=s(e,n??`#000000`),i=f(r),a=f(s(t,`#000000`));return!i||!a||p(i,a)>=4.5?r:p({blue:0,green:0,red:0},a)>=p({blue:255,green:255,red:255},a)?`#000000`:`#ffffff`}function o(e,t,n){let r=e.palette??{},i=t.map(e=>r[e]).find(e=>typeof e==`string`&&e.trim()!==``);return d(i,e.background,4.5)?s(i,n):d(n,e.background,4.5)?n:a(i,e.background,n)}function s(e,t){return typeof e==`string`&&e.trim()!==``?e.trim():t}function c(e){let t=typeof e==`string`&&e.trim()!==``?e.trim():`Menlo`;return`${JSON.stringify(t)}, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace`}function l(e,t){return typeof e==`number`&&Number.isFinite(e)&&e>0?e:t}function u(e){return typeof e!=`number`||!Number.isFinite(e)?1:Math.max(0,Math.min(1,e))}function d(e,t,n){let r=f(s(e,``)),i=f(s(t,`#000000`));return!!(r&&i&&p(r,i)>=n)}function f(e){let t=e.trim(),n=t.match(/^#([0-9a-f]{3})$/i);if(n){let[,e]=n;return{red:Number.parseInt(e[0]+e[0],16),green:Number.parseInt(e[1]+e[1],16),blue:Number.parseInt(e[2]+e[2],16)}}let r=t.match(/^#([0-9a-f]{6})$/i);if(!r)return null;let[,i]=r;return{red:Number.parseInt(i.slice(0,2),16),green:Number.parseInt(i.slice(2,4),16),blue:Number.parseInt(i.slice(4,6),16)}}function p(e,t){let n=Math.max(m(e),m(t)),r=Math.min(m(e),m(t));return(n+.05)/(r+.05)}function m(e){return .2126*h(e.red)+.7152*h(e.green)+.0722*h(e.blue)}function h(e){let t=e/255;return t<=.03928?t/12.92:((t+.055)/1.055)**2.4}function g(e,t,n=!1,r){let i=Error(t);return i.name=`PageError`,i.code=e,i.retryable=n,r!==void 0&&(i.details=r),i}function _(e){return e instanceof Error&&typeof e.code==`string`}var v=`__cmuxPageReceive`,y=class{handler;nextId=1;listeners=new Map;lastSeq=new Map;handlers=new Map;constructor(e,t=globalThis){this.handler=e,t[v]=e=>this.receive(e)}async call(e,t){return await this.post({t:`call`,id:this.nextId++,op:e,params:t})}async subscribe(e,t,n){let r=n?{t:`sub`,id:this.nextId++,stream:e,filter:n}:{t:`sub`,id:this.nextId++,stream:e},i=(await this.post(r))?.sub;if(typeof i!=`number`)throw g(`cmux.protocol.invalid_result`,`subscribe ${e}: no sub id`);return this.listeners.set(i,t),()=>{this.listeners.delete(i)&&(this.lastSeq.delete(i),this.handler.postMessage({t:`unsub`,sub:i}).catch(()=>void 0))}}handle(e,t){return this.handlers.set(e,t),()=>{this.handlers.get(e)===t&&this.handlers.delete(e)}}async post(e){let t;try{t=await this.handler.postMessage(e)}catch(e){throw g(`cmux.protocol.closed`,e instanceof Error?e.message:String(e),!0)}let n=t;if(n?.t===`ok`&&n.id===e.id)return n.value;if(n?.t===`err`){let e=n;throw g(e.code??`cmux.protocol.error`,e.message??`request failed`,e.retryable??!1,e.details)}throw g(`cmux.protocol.invalid_result`,`malformed reply`)}receive(e){let t=e;if(t?.t===`ev`){let{sub:e,seq:n,data:r}=t,i=this.listeners.get(e);if(!i||n<=(this.lastSeq.get(e)??0))return;this.lastSeq.set(e,n),i(r,n);return}if(t?.t===`call`){let{id:e,op:n,params:r}=t;this.answer(e,n,r)}}async answer(e,t,n){let r=this.handlers.get(t),i;if(!r)i={t:`err`,id:e,code:`cmux.protocol.unknown_op`,message:t};else try{i={t:`ok`,id:e,value:await r(n)??null}}catch(t){i={t:`err`,id:e,code:`cmux.page.failed`,message:t instanceof Error?t.message:String(t)}}await this.handler.postMessage(i).catch(()=>void 0)}};function b(e=`cmuxPage`,t=globalThis){let n=t.webkit?.messageHandlers?.[e];return n&&typeof n.postMessage==`function`?n:null}function x(e){let t=b();return t?new y(t):e?e():null}var S={light:{0:`#1a1a1a`,1:`#cc372e`,2:`#26a439`,3:`#cdac08`,4:`#0869cb`,5:`#9647bf`,6:`#479ec2`,7:`#98989d`,8:`#464646`,9:`#ff453a`,10:`#32d74b`,11:`#e5bc00`,12:`#0a84ff`,13:`#bf5af2`,14:`#69c9f2`,15:`#ffffff`},dark:{0:`#1a1a1a`,1:`#cc372e`,2:`#26a439`,3:`#cdac08`,4:`#0869cb`,5:`#9647bf`,6:`#479ec2`,7:`#98989d`,8:`#464646`,9:`#ff453a`,10:`#32d74b`,11:`#ffd60a`,12:`#0a84ff`,13:`#bf5af2`,14:`#76d6ff`,15:`#ffffff`}};function C(e,t,n,r,i,a=3){let o=t.map(t=>e[String(t)]).find(T)??t.map(e=>S[n][String(e)]).find(T);return o==null?i:w(o,r,i,a)}function w(e,t,n,r){let i=E(e),a=E(t),o=E(n);if(i==null||a==null||o==null)return e.trim();if(k(i,a)>=r)return D(i);for(let e=1;e<=20;e++){let t=O(i,o,e/20);if(k(t,a)>=r)return D(t)}return D(o)}function T(e){return typeof e==`string`&&e.trim()!==``}function E(e){let t=e.trim().replace(/^#/,``);return/^[0-9a-f]{3}$/i.test(t)?[0,1,2].map(e=>Number.parseInt(t[e]+t[e],16)):/^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(t)?[0,2,4].map(e=>Number.parseInt(t.slice(e,e+2),16)):null}function D(e){return`#${e.map(e=>Math.round(e).toString(16).padStart(2,`0`)).join(``)}`}function O(e,t,n){return e.map((e,r)=>e+(t[r]-e)*n)}function k(e,t){let[n,r]=[A(e),A(t)].sort((e,t)=>t-e);return(n+.05)/(r+.05)}function A([e,t,n]){let r=e=>{let t=e/255;return t<=.03928?t/12.92:((t+.055)/1.055)**2.4};return .2126*r(e)+.7152*r(t)+.0722*r(n)}function j(e,t){return{layout:{paddingTop:0,gap:1,paddingBottom:0},itemMetrics:{diffHeaderHeight:32},diffStyle:e.layout,diffIndicators:e.diffIndicators,overflow:e.wordWrap?`wrap`:`scroll`,expandUnchanged:e.expandUnchanged,disableBackground:!e.showBackgrounds,disableLineNumbers:!e.lineNumbers,lineHoverHighlight:`number`,enableLineSelection:!0,enableGutterUtility:!0,lineDiffType:e.wordDiffs?`word`:`none`,stickyHeaders:!0,unsafeCSS:N(),theme:t.theme,themeType:`system`}}function M(e,t,n=[`text`]){return{langs:n,theme:t.theme,preferredHighlighter:`shiki-wasm`,lineDiffType:e.wordDiffs?`word`:`none`,maxLineDiffLength:1e3,tokenizeMaxLineLength:1e3,useTokenTransformer:!1}}function N(){return`
    :host {
      /* Code rows and separators are clear over the page's one backdrop
         (only html paints it, so a translucent backdrop never stacks). */
      --diffs-light-bg: transparent;
      --diffs-dark-bg: transparent;
      --diffs-bg-buffer-override: color-mix(in srgb, var(--cmux-diff-fg) 12%, transparent);
      --diffs-bg-context-override: transparent;
      --diffs-bg-context-gutter-override: transparent;
      --diffs-bg-separator-override: transparent;
      background-color: transparent;
      --diffs-addition-color-override: light-dark(var(--cmux-diff-addition-fg-light), var(--cmux-diff-addition-fg-dark));
      --diffs-deletion-color-override: light-dark(var(--cmux-diff-deletion-fg-light), var(--cmux-diff-deletion-fg-dark));
      --diffs-fg-number-addition-override: var(--diffs-addition-base);
      --diffs-fg-number-deletion-override: var(--diffs-deletion-base);
      --diffs-bg-addition-override: color-mix(in srgb, var(--diffs-addition-base) 34%, transparent);
      --diffs-bg-deletion-override: color-mix(in srgb, var(--diffs-deletion-base) 34%, transparent);
      --diffs-bg-addition-emphasis-override: color-mix(in srgb, var(--diffs-addition-base) 30%, transparent);
      --diffs-bg-deletion-emphasis-override: color-mix(in srgb, var(--diffs-deletion-base) 30%, transparent);
    }
    pre,
    code {
      background-color: transparent;
    }
    /* The file header is never transparent (Lawrence): it paints the
       backdrop composited onto the theme color at full alpha, so scrolled
       code never shows through it, even over a see-through window. Its
       content is the slotted FileHeader (renderCustomHeader), so the row's
       height is fixed to the virtualizer's diffHeaderHeight metric. */
    [data-diffs-header] {
      height: var(--cmux-diff-file-header-height, 32px);
      min-height: 0;
      display: flex;
      align-items: stretch;
      background-color: var(--cmux-diff-solid-bg);
      border-bottom: 1px solid var(--cmux-diff-border);
    }
    [data-line-type='change-addition']:where([data-column-number], [data-gutter-buffer]) {
      color: var(--diffs-addition-base);
    }
    [data-line-type='change-deletion']:where([data-column-number], [data-gutter-buffer]) {
      color: var(--diffs-deletion-base);
    }
    [data-gutter-buffer='buffer'] {
      background-position: 5px 0;
      background-size: 8px 8px;
      background-origin: border-box;
      background-image: repeating-linear-gradient(
        -45deg,
        transparent,
        transparent 4.242px,
        var(--diffs-bg-buffer) 4.242px,
        var(--diffs-bg-buffer) 5.656px
      );
    }
    [data-separator='line-info'] {
      background-color: transparent;
    }
    [data-utility-button] {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 18px;
      height: 18px;
      padding: 0;
      border: 0;
      border-radius: 4px;
      background: var(--cmux-diff-accent, light-dark(#0a84ff, #7ab7ff));
      color: light-dark(#fff, #08233f);
      cursor: pointer;
      transform: scale(0.9);
      transition: transform 80ms ease;
    }
    [data-utility-button]:hover {
      transform: scale(1.1);
    }
    [data-utility-button] [data-icon] {
      width: 12px;
      height: 12px;
    }
    [data-separator='line-info'] [data-separator-wrapper],
    [data-separator='line-info'] [data-separator-content],
    [data-separator='line-info'] [data-expand-button] {
      background-color: transparent;
    }
    [data-diffs-header],
    [data-separator-wrapper],
    [data-separator-content],
    [data-unmodified-lines],
    [data-expand-button] {
      font-family: var(--diffs-header-font-family, var(--diffs-header-font-fallback));
    }
  `}function P(){return`
    :host {
      display: block;
      height: 100%;
      min-height: 0;
      background-color: var(--cmux-diff-solid-bg);
    }
    [data-file-tree-search-container][data-open='false'] {
      display: none;
    }
    [data-file-tree-search-container] {
      margin: 0 4px 6px 0;
      padding: 0 5px 6px 1px;
      border-bottom: 1px solid var(--trees-border-color);
    }
    [data-file-tree-virtualized-scroll='true'] {
      height: 100%;
      min-height: 0;
      overflow: auto;
      background-color: var(--cmux-diff-solid-bg);
      padding-inline-start: 0;
      padding-inline-end: 2px;
      margin-inline-end: 2px;
      scrollbar-gutter: stable;
    }
    [data-item-section='content'] {
      flex: 1 1 auto;
      min-width: 0;
    }
    /* +N -N change counts (the row decoration), right-aligned and tabular. A
       one-sided count takes the row's added or deleted status color. */
    [data-item-section='decoration'] {
      flex: 0 0 auto;
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
    [data-item-git-status='added'] > [data-item-section='decoration'] {
      color: var(--trees-status-added);
    }
    [data-item-git-status='deleted'] > [data-item-section='decoration'] {
      color: var(--trees-status-deleted);
    }
    [data-file-tree-sticky-overlay-content] {
      background-color: var(--cmux-diff-solid-bg) !important;
      box-shadow: 0 1px 0 var(--trees-border-color);
    }
  `}function F(e,t){let n=e.palette??{},r=i(e.background,t),o=L(e),s=a(e.foreground,o,e.type===`light`?`#000000`:`#ffffff`),c=(e,t=s)=>a(e,o,t);return{name:e.name,displayName:e.ghosttyName,type:e.type,colors:{"editor.background":r,"editor.foreground":s,"terminal.background":r,"terminal.foreground":s,"terminal.ansiBlack":c(n[0]),"terminal.ansiRed":c(n[1]),"terminal.ansiGreen":c(n[2]),"terminal.ansiYellow":c(n[3]),"terminal.ansiBlue":c(n[4]),"terminal.ansiMagenta":c(n[5]),"terminal.ansiCyan":c(n[6]),"terminal.ansiWhite":c(n[7]),"terminal.ansiBrightBlack":c(n[8]),"terminal.ansiBrightRed":c(n[9],c(n[1])),"terminal.ansiBrightGreen":c(n[10],c(n[2])),"terminal.ansiBrightYellow":c(n[11],c(n[3])),"terminal.ansiBrightBlue":c(n[12],c(n[4])),"terminal.ansiBrightMagenta":c(n[13],c(n[5])),"terminal.ansiBrightCyan":c(n[14],c(n[6])),"terminal.ansiBrightWhite":c(n[15]),"gitDecoration.addedResourceForeground":c(n[10],c(n[2],`#32d74b`)),"gitDecoration.deletedResourceForeground":c(n[9],c(n[1],`#ff453a`)),"gitDecoration.modifiedResourceForeground":c(n[12],c(n[4],`#0a84ff`)),"editor.selectionBackground":e.selectionBackground,"editor.selectionForeground":e.selectionForeground},tokenColors:I(e,s,r,o)}}function I(e,t,n,r){let i=e.type===`light`?`light`:`dark`,a=(...n)=>C(e.palette??{},n,i,r,t);return[{settings:{foreground:t,background:n}},{scope:[`comment`,`punctuation.definition.comment`,`string.comment`],settings:{foreground:a(8),fontStyle:`italic`}},{scope:[`string`,`constant.other.symbol`,`string.regexp`],settings:{foreground:a(2)}},{scope:[`constant.numeric`,`constant.language`,`constant.character`,`support.constant`,`variable.other.enummember`],settings:{foreground:a(3)}},{scope:[`keyword`,`storage`,`storage.type`,`storage.modifier`,`keyword.operator.new`,`keyword.control`],settings:{foreground:a(5)}},{scope:[`entity.name.function`,`support.function`,`meta.function-call entity.name.function`],settings:{foreground:a(4)}},{scope:[`entity.name.type`,`entity.name.class`,`entity.other.inherited-class`,`support.type`,`support.class`],settings:{foreground:a(6)}},{scope:[`entity.name.tag`,`meta.tag.sgml`,`entity.name.section`],settings:{foreground:a(1)}},{scope:[`entity.other.attribute-name`],settings:{foreground:a(3)}},{scope:[`markup.heading`,`punctuation.definition.heading`],settings:{foreground:a(12,4),fontStyle:`bold`}},{scope:[`markup.bold`,`punctuation.definition.bold`],settings:{foreground:a(11,3),fontStyle:`bold`}},{scope:[`markup.italic`,`punctuation.definition.italic`],settings:{foreground:a(13,5),fontStyle:`italic`}},{scope:[`markup.inline.raw`,`markup.raw`,`markup.fenced_code`,`markup.raw.block`],settings:{foreground:a(10,2)}},{scope:[`markup.underline.link`,`string.other.link`,`markup.link`],settings:{foreground:a(14,6)}},{scope:[`markup.quote`,`punctuation.definition.quote`],settings:{foreground:a(8),fontStyle:`italic`}},{scope:[`punctuation.definition.list`,`markup.table`],settings:{foreground:a(9,1)}},{scope:[`markup.inserted`,`punctuation.definition.inserted`],settings:{foreground:a(2)}},{scope:[`markup.deleted`,`punctuation.definition.deleted`],settings:{foreground:a(1)}},{scope:[`variable`,`meta.definition.variable`],settings:{foreground:t}},{scope:[`invalid`,`message.error`],settings:{foreground:a(9,1)}}]}function L(e){return typeof e.background==`string`&&e.background.trim()!==``?e.background.trim():e.type===`light`?`#ffffff`:`#000000`}export{x as a,n as c,M as i,P as n,_ as o,F as r,r as s,j as t};