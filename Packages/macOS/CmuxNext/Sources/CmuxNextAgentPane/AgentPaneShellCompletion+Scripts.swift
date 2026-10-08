/// The scripts ``AgentPaneShellCompletion`` hands each shell. They hold no command names: every
/// candidate comes from the shell's own completion machinery.
nonisolated extension AgentPaneShellCompletion {
    /// The outer zsh: starts an interactive `zsh -f` on a pseudo terminal, loads the completion
    /// system into it (``zshSetup``), types the line and Tab, and copies what the pty prints.
    static let zshDriver = #"""
    emulate -L zsh
    zmodload zsh/zpty || exit 3
    export TERM=xterm
    zpty cmuxcomplete "$2" -d -i || exit 4
    zpty -w cmuxcomplete 'eval "$CMUX_COMPLETE_SETUP"'
    local out ready=0
    repeat 16; do
      zpty -r cmuxcomplete out || break
      if [[ $out == *cmux-complete-ready* ]]; then ready=1; break; fi
    done
    (( ready )) || exit 5
    zpty -w cmuxcomplete "$1"$'\t'
    while zpty -r cmuxcomplete; do :; done
    """#

    /// The inner zsh: no prompt, Return does nothing, Tab completes; `compadd` is wrapped so each
    /// match prints as one line (`value -- description`) between two NUL lines, then the shell exits.
    static let zshSetup = #"""
    PROMPT= RPROMPT= PS2=
    unset zle_bracketed_paste
    for d in /opt/homebrew/share/zsh/site-functions /usr/local/share/zsh/site-functions; do
      [[ -d $d ]] && fpath+=($d)
    done
    autoload -Uz compinit
    compinit -i -d "$CMUX_COMPLETE_DUMP"
    bindkey '^M' undefined
    bindkey '^J' undefined
    bindkey '^I' complete-word
    cmux-complete-null() { echo -E - $'\0' }
    compprefuncs=( cmux-complete-null )
    comppostfuncs=( cmux-complete-null exit )
    zstyle ':completion:*' list-grouped false
    zstyle ':completion:*' insert-tab false
    zstyle ':completion:*' list-separator ''
    zmodload zsh/zutil
    compadd() {
      if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then
        builtin compadd "$@"
        return $?
      fi
      typeset -a __hits __dscr __tmp
      if (( $@[(I)-d] )); then
        __tmp=${@[$[${@[(i)-d]}+1]]}
        if [[ $__tmp == \(* ]]; then
          eval "__dscr=$__tmp"
        else
          __dscr=( "${(@P)__tmp}" )
        fi
      fi
      builtin compadd -A __hits -D __dscr "$@"
      setopt localoptions norcexpandparam extendedglob
      typeset -A apre hpre hsuf asuf
      zparseopts -E P:=apre p:=hpre S:=asuf s:=hsuf
      integer dirsuf=0
      if [[ -z $hsuf && "${${@//-default-/}% -# *}" == *-[[:alnum:]]#f* ]]; then
        dirsuf=1
      fi
      [[ -n $__hits ]] || return
      local dsuf dscr full
      for i in {1..$#__hits}; do
        full=$IPREFIX$apre$hpre$__hits[$i]
        dsuf=
        (( dirsuf )) && [[ $full$hsuf$asuf != */ && -d ${full/#\~/$HOME} ]] && dsuf=/
        (( $#__dscr >= $i )) && dscr=" -- ${${__dscr[$i]}##$__hits[$i] #}" || dscr=
        echo -E - $full$dsuf$hsuf$asuf$dscr
      done
    }
    echo cmux-complete-ready
    """#

    /// bash: commands (aliases, builtins, functions, keywords, `PATH`) in command position, else
    /// files with directories marked; `$1` is the word without its quotes or backslashes.
    static let bashScript = #"""
    printf '\0'
    if [[ $2 == 1 ]]; then
      compgen -A alias -A builtin -A command -A function -A keyword -- "$1" | sort -u
    else
      compgen -f -- "$1" | while IFS= read -r f; do
        t=$f; [[ $t == "~"* ]] && t=$HOME${t:1}
        if [[ -d $t && $f != */ ]]; then printf '%s/\n' "$f"; else printf '%s\n' "$f"; fi
      done
    fi
    printf '\0'
    """#

    /// fish: its own completions for the whole line, `candidate<TAB>description` per line.
    static let fishScript = #"""
    printf '\0'
    complete -C -- $argv[1]
    printf '\0'
    """#
}
