import{d as f,c as E,a2 as N,Q as M,S as P,U as F,G as T,B as H,D as K,Y as I,q as R,s as W,O as $,R as G,a5 as O,$ as _,t as q,y as U,a6 as V,V as Y,J as j,_ as A,C as g,h as z,a1 as J,aa as Q,a3 as X,x as Z}from"./editor-vendor.mjs";import{i as ee}from"./installWebviewStyles.mjs";import"./vendor.mjs";const x=new Set;typeof window<"u"&&(window.cmuxEditorBridge={receive(t){for(const e of x)e(t)}});function te(t){return x.add(t),()=>{x.delete(t)}}let w=0;async function b(t,e={}){const o=typeof window>"u"?void 0:window.webkit?.messageHandlers?.cmuxEditor;if(!o||typeof o.postMessage!="function")throw new Error("Native editor bridge is unavailable.");w+=1;const n=await o.postMessage({id:`editor-${w}`,method:t,params:e});if(!n.ok)throw new Error(n.error?.userMessage||"Native editor bridge request failed.");return n.value}class re{baseline;pendingConflict=!1;constructor(e){this.baseline=e}isDirty(e){return e!==this.baseline}hasPendingConflict(){return this.pendingConflict}diskContent(){return this.baseline}applyExternal(e,o){const n=e===this.baseline;return this.baseline=o,o===e?(this.pendingConflict=!1,{kind:"none"}):n?(this.pendingConflict=!1,{kind:"replaceBuffer",content:o}):(this.pendingConflict=!0,{kind:"showConflict"})}noteSaved(e){this.baseline=e,this.pendingConflict=!1}resolveConflictReload(){return this.pendingConflict=!1,this.baseline}resolveConflictKeepMine(){this.pendingConflict=!1}}const oe=100,ne=`
  html, body {
    margin: 0;
    height: 100%;
    background: transparent;
    overscroll-behavior: none;
  }
  #root {
    display: flex;
    flex-direction: column;
    height: 100%;
  }
  .cmux-editor-banner {
    display: none;
    align-items: center;
    gap: 8px;
    padding: 6px 10px;
    font: 12px -apple-system, system-ui, sans-serif;
    color: var(--cmux-editor-fg, #000);
    background: var(--cmux-editor-surface, rgba(127, 127, 127, 0.15));
    border-bottom: 1px solid var(--cmux-editor-border, rgba(127, 127, 127, 0.4));
  }
  .cmux-editor-banner.cmux-editor-banner-visible {
    display: flex;
  }
  .cmux-editor-banner-message {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .cmux-editor-banner-error .cmux-editor-banner-message {
    color: var(--cmux-editor-danger, #b3261e);
  }
  .cmux-editor-banner button {
    font: inherit;
    padding: 2px 10px;
    border-radius: 5px;
    border: 1px solid var(--cmux-editor-border, rgba(127, 127, 127, 0.4));
    background: transparent;
    color: var(--cmux-editor-fg, #000);
    cursor: pointer;
  }
  .cmux-editor-banner button.cmux-editor-banner-primary {
    background: var(--cmux-editor-accent-soft, rgba(0, 122, 255, 0.18));
    border-color: var(--cmux-editor-accent, #007aff);
  }
  .cmux-editor-container {
    flex: 1;
    min-height: 0;
  }
  .cmux-editor-container .cm-editor {
    height: 100%;
  }
`,ae=f.theme({"&":{backgroundColor:"var(--cmux-editor-bg, transparent)",color:"var(--cmux-editor-fg, inherit)",fontSize:"12px"},".cm-scroller":{fontFamily:"ui-monospace, 'SF Mono', Menlo, monospace",lineHeight:"1.5"},".cm-content":{caretColor:"var(--cmux-editor-fg, auto)"},".cm-gutters":{backgroundColor:"transparent",color:"var(--cmux-editor-muted, inherit)",border:"none"},".cm-activeLineGutter":{backgroundColor:"transparent",color:"var(--cmux-editor-fg, inherit)"},".cm-activeLine":{backgroundColor:"color-mix(in srgb, var(--cmux-editor-fg, currentColor) 5%, transparent)"},"&.cm-focused .cm-cursor":{borderLeftColor:"var(--cmux-editor-fg, auto)"},"&.cm-focused > .cm-scroller .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, & ::selection":{backgroundColor:"var(--cmux-editor-accent-soft, rgba(0, 122, 255, 0.2)) !important"},".cm-panels":{backgroundColor:"var(--cmux-editor-panel, Canvas)",color:"var(--cmux-editor-fg, inherit)",border:"none"},".cm-panels.cm-panels-top":{borderBottom:"1px solid var(--cmux-editor-border, rgba(127, 127, 127, 0.4))"},".cm-panels.cm-panels-bottom":{borderTop:"1px solid var(--cmux-editor-border, rgba(127, 127, 127, 0.4))"}});function C(t){const e=document.documentElement.style;e.setProperty("--cmux-editor-bg",t.pageBackground),e.setProperty("--cmux-editor-fg",t.text),e.setProperty("--cmux-editor-muted",t.mutedText),e.setProperty("--cmux-editor-accent",t.accent),e.setProperty("--cmux-editor-accent-soft",t.accentSoft),e.setProperty("--cmux-editor-border",t.border),e.setProperty("--cmux-editor-surface",t.surfaceBackground),e.setProperty("--cmux-editor-panel",t.surfaceElevatedBackground),e.setProperty("--cmux-editor-danger",t.danger),e.setProperty("color-scheme",t.isDark?"dark":"light")}function k(t){return[ae,Q(t?X:Z,{fallback:!0})]}const ie={Find:"検索",Replace:"置換",next:"次へ",previous:"前へ",all:"すべて","match case":"大文字と小文字を区別","by word":"単語単位",regexp:"正規表現",replace:"置換","replace all":"すべて置換",close:"閉じる","current match":"現在の一致","replaced $ matches":"$ 件置換しました","replaced match on line $":"$ 行目の一致を置換しました","on line":"行","Go to line":"行へ移動",go:"移動","Folded lines":"折りたたまれた行",unfold:"展開","Fold line":"行を折りたたむ","Unfold line":"行を展開","Control character":"制御文字","Selection deleted":"選択範囲を削除しました"};function se(t){return t.toLowerCase().startsWith("ja")?[E.phrases.of(ie)]:[]}function S(t){return t?[f.lineWrapping]:[]}function ce(t,e,o){const n=document.createElement("div");n.className="cmux-editor-banner";const l=document.createElement("span");l.className="cmux-editor-banner-message";const s=document.createElement("button");s.className="cmux-editor-banner-primary",s.textContent=t.reloadFromDisk,s.addEventListener("click",e);const d=document.createElement("button");return d.textContent=t.keepMyChanges,d.addEventListener("click",o),n.append(l,s,d),{element:n,show(u){const c=u==="conflict";l.textContent=c?t.fileChangedOnDisk:t.saveFailed,n.classList.toggle("cmux-editor-banner-error",!c),s.style.display=c?"":"none",d.style.display=c?"":"none",n.classList.add("cmux-editor-banner-visible")},hide(){n.classList.remove("cmux-editor-banner-visible")}}}async function de(t){const e=await b("editor.ready");C(e.theme),ee("editor",ne);const o=new re(e.diskContent),n=new g,l=new g,s=new g;let d=o.isDirty(e.content),u=null,c=!1;const m=()=>{const r=o.isDirty(a.state.doc.toString());r!==d&&(d=r,b("editor.dirtyChanged",{isDirty:r}).catch(()=>{}))},D=()=>{u!==null&&clearTimeout(u),u=setTimeout(()=>{u=null,m()},oe)},y=r=>{const p=a.state.selection.main.head;a.dispatch({changes:{from:0,to:a.state.doc.length,insert:r},selection:{anchor:Math.min(p,r.length)}})},B=async()=>{if(c)return;c=!0;const r=a.state.doc.toString();try{(await b("editor.save",{content:r})).saved?(o.noteSaved(r),i.hide()):i.show("error")}catch{i.show("error")}finally{c=!1,m()}},i=ce(e.copy,()=>{y(o.resolveConflictReload()),i.hide(),m(),a.focus()},()=>{o.resolveConflictKeepMine(),i.hide(),m(),a.focus()}),a=new f({state:E.create({doc:e.content,extensions:[N(),M(),P(),F(),T(),H(),K(),I(),R(),W(),$(),G(),O({top:!0}),_.of([{key:"Mod-s",run:()=>(B(),!0)},...q,...U,...V,...Y,...j,A]),n.of([]),l.of(k(e.theme.isDark)),s.of(S(e.wordWrap)),se(e.locale??"en"),f.updateListener.of(r=>{r.docChanged&&D()})]})}),h=document.createElement("div");h.className="cmux-editor-container",h.append(a.dom),t.append(i.element,h),window.cmuxEditorHost={getContent:()=>a.state.doc.toString()},te(r=>{switch(r.type){case"document.external":{const p=o.applyExternal(a.state.doc.toString(),r.content);p.kind==="replaceBuffer"?(y(p.content),i.hide()):p.kind==="showConflict"?i.show("conflict"):i.hide(),m();break}case"document.saved":{o.noteSaved(r.content),i.hide(),m();break}case"app.theme":{C(r.theme),a.dispatch({effects:l.reconfigure(k(r.theme.isDark))});break}case"app.options":{a.dispatch({effects:s.reconfigure(S(r.wordWrap))});break}}});const L=e.path.split("/").pop()??e.path,v=z.matchFilename(J,L);v&&v.load().then(r=>{a.dispatch({effects:n.reconfigure(r)})}),window.addEventListener("focus",()=>{a.focus()}),document.hasFocus()&&a.focus()}function pe(t){de(t)}export{pe as mountEditorSurface};
