use super::*;

#[derive(Clone, Debug, Default)]
pub struct SessionUpdate {
    pub workspace_id: String,
    pub surface_id: String,
    pub cwd: Option<String>,
    pub transcript_path: Option<String>,
    pub pid: Option<i64>,
    pub launch_command: Option<Value>,
    pub is_restorable: Option<bool>,
    pub agent_lifecycle: Option<String>,
    pub hook_event_name: Option<String>,
    pub last_subtitle: Option<String>,
    pub last_body: Option<String>,
    pub update_last_summary: bool,
    pub last_notification_status: Option<String>,
    pub update_last_notification_status: bool,
    pub runtime_status: Option<String>,
    pub update_runtime_status: bool,
    pub had_pending_background_work_at_stop: Option<bool>,
    pub title: Option<String>,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PromptSubmitResult { pub stale_terminal_turn: bool, pub nested: bool }

fn optional(s: &Option<String>) -> Option<String> { normalize(s.as_deref()) }
fn make_record(state:&ClaudeHookState,id:&str,u:&SessionUpdate,time:f64)->ClaudeHookSessionRecord {
    state.sessions.get(id).cloned().unwrap_or_else(||ClaudeHookSessionRecord {session_id:id.into(),workspace_id:u.workspace_id.clone(),surface_id:u.surface_id.clone(),started_at:time,updated_at:time,..Default::default()})
}
fn generation_value(pid:i64,seconds:i64,microseconds:i64)->Value {serde_json::json!({"pid":pid,"startSeconds":seconds,"startMicroseconds":microseconds})}
impl ClaudeHookSessionRecord {
    pub fn update_process_generation(&mut self,pid:i64,identity:Option<(i64,i64)>) {
        let previous_pid=self.pid;
        let previous=previous_pid.zip(self.pid_start_seconds.zip(self.pid_start_microseconds)).map(|(p,(s,u))|generation_value(p,s,u));
        self.pid=Some(pid);
        if let Some((s,u))=identity {
            let incoming=generation_value(pid,s,u);
            if previous.as_ref()!=Some(&incoming) {let mut prior=self.prior_process_generations.take().unwrap_or_default();prior.retain(|g|g!=&incoming);if let Some(previous)=previous {prior.insert(0,previous)}prior.truncate(4);self.prior_process_generations=Some(prior)}
            self.pid_start_seconds=Some(s);self.pid_start_microseconds=Some(u);
        } else if previous_pid!=Some(pid) {
            if let Some(previous)=previous {let mut prior=self.prior_process_generations.take().unwrap_or_default();prior.retain(|g|g!=&previous);prior.insert(0,previous);prior.truncate(4);self.prior_process_generations=Some(prior)}
            self.pid_start_seconds=None;self.pid_start_microseconds=None;
        }
    }
    pub fn process_identity(&self,pid:i64)->Option<CodexProcessGeneration> {
        if self.pid==Some(pid)&&(self.pid_start_seconds.is_none()||self.pid_start_microseconds.is_none()){return None}
        let current=if self.pid==Some(pid){self.pid_start_seconds.zip(self.pid_start_microseconds).map(|(s,u)|generation_value(pid,s,u))}else{None};
        let generation=current.or_else(||self.prior_process_generations.as_ref()?.iter().find(|v|v["pid"].as_i64()==Some(pid)).cloned())?;
        let s=generation["startSeconds"].as_i64()?;let u=generation["startMicroseconds"].as_i64()?;
        if (s==0&&u==0)||pid>i32::MAX as i64||pid<i32::MIN as i64{return None}
        Some(CodexProcessGeneration{pid,start_seconds:s,start_microseconds:u})
    }
}
pub(super) fn update_record(r:&mut ClaudeHookSessionRecord,u:&SessionUpdate,time:f64) {
    r.workspace_id=u.workspace_id.clone();if !u.surface_id.is_empty(){r.surface_id=u.surface_id.clone()}
    if let Some(c)=optional(&u.cwd){r.cwd=Some(c)}if let Some(t)=optional(&u.title){r.title=Some(t)}if let Some(t)=optional(&u.transcript_path){r.transcript_path=Some(t)}
    if let Some(pid)=u.pid{r.update_process_generation(pid,process::claude_process_start_identity(pid));}
    if let Some(incoming)=&u.launch_command {
        let existing_args=r.launch_command.as_ref().and_then(|v|v["arguments"].as_array()).is_some_and(|a|!a.is_empty());
        let incoming_args=incoming["arguments"].as_array().is_some_and(|a|!a.is_empty());
        let incoming_env=incoming["environment"].as_object().is_some_and(|e|!e.is_empty());
        let source=normalize(incoming["source"].as_str()).map(|s|s.to_lowercase());
        let existing_codex=r.launch_command.as_ref().and_then(|v|normalize(v["environment"]["CODEX_HOME"].as_str()));
        if incoming_args||source.as_deref()==Some("rejected")||(source.as_deref()==Some("default")&&!existing_args&&existing_codex.is_none())||(incoming_env&&!existing_args){r.launch_command=Some(incoming.clone())}
        else if let Some(home)=normalize(incoming["verificationHome"].as_str()){if let Some(existing)=r.launch_command.as_mut(){if normalize(existing["verificationHome"].as_str()).is_none(){existing["verificationHome"]=Value::String(home)}}}
    }
    if let Some(restorable)=u.is_restorable {r.is_restorable=Some(restorable||r.is_restorable==Some(true))}
    if let Some(lifecycle)=&u.agent_lifecycle{r.agent_lifecycle=Some(lifecycle.clone())}
    if let Some(event)=optional(&u.hook_event_name){r.hook_event_name=Some(event)}
    if u.update_last_summary{r.last_subtitle=optional(&u.last_subtitle);r.last_body=optional(&u.last_body)}else{if let Some(s)=optional(&u.last_subtitle){r.last_subtitle=Some(s)}if let Some(b)=optional(&u.last_body){r.last_body=Some(b)}}
    if u.update_last_notification_status {r.last_notification_status=u.last_notification_status.clone()}
    if u.update_runtime_status{r.runtime_status=u.runtime_status.clone()}
    if let Some(pending)=u.had_pending_background_work_at_stop{r.had_pending_background_work_at_stop=Some(pending)}
    r.updated_at=time;
}
fn active_stack(r:&ClaudeHookSessionRecord)->Vec<String>{let ids=r.active_prompt_turn_ids.as_ref().map(|ids|ids.iter().filter_map(|x|normalize(Some(x))).collect::<Vec<_>>()).unwrap_or_default();if !ids.is_empty(){ids}else{normalize(r.active_prompt_turn_id.as_deref()).into_iter().collect()}}
fn set_active_stack(r:&mut ClaudeHookSessionRecord,stack:Vec<String>,depth:i64){let depth=depth.max(0).max(stack.len() as i64);r.active_prompt_depth=(depth>0).then_some(depth);r.active_prompt_turn_id=if depth>0{stack.last().cloned()}else{None};r.active_prompt_turn_ids=if depth>0&&!stack.is_empty(){Some(stack)}else{None};}
fn terminal_stack(r:&ClaudeHookSessionRecord)->Vec<String>{r.terminal_prompt_turn_ids.as_ref().map(|v|v.iter().filter_map(|s|normalize(Some(s))).collect()).unwrap_or_default()}
fn mark_terminal(r:&mut ClaudeHookSessionRecord,id:&str){let Some(id)=normalize(Some(id))else{return};let mut ids=terminal_stack(r);ids.retain(|s|s!=&id);ids.push(id.clone());if ids.len()>32{ids.drain(..ids.len()-32);}r.last_prompt_turn_id=Some(id);r.terminal_prompt_turn_ids=Some(ids);}
fn append_messages(r:&mut ClaudeHookSessionRecord,messages:&[Value]){if messages.is_empty(){return}let mut recent=r.auto_name_recent_messages.take().unwrap_or_default();let mut appended=0;for message in messages{let role=message["role"].as_str().unwrap_or("").trim().to_lowercase();if role!="user"&&role!="assistant"{continue}let text=message["text"].as_str().unwrap_or("").split_whitespace().collect::<Vec<_>>().join(" ");if text.is_empty(){continue}let text=if text.chars().count()>1000{format!("{}…",text.chars().take(999).collect::<String>())}else{text};let normalized=serde_json::json!({"role":role,"text":text});if recent.last()==Some(&normalized){continue}recent.push(normalized);appended+=1;}if recent.len()>24{recent.drain(..recent.len()-24);}r.auto_name_recent_messages=(!recent.is_empty()).then_some(recent);if appended>0{r.auto_name_message_sequence=Some(r.auto_name_message_sequence.unwrap_or(0)+appended);}}
fn stale_start(r:&ClaudeHookSessionRecord,pid:Option<i64>,include_terminal:bool)->bool{if r.active_prompt_depth.unwrap_or(0).max(r.active_prompt_turn_ids.as_ref().map_or(0,|v|v.len() as i64))>0{return true}let completed=normalize(r.last_prompt_turn_id.as_deref()).is_some()||(include_terminal&&!terminal_stack(r).is_empty());completed&&pid.is_some()&&r.pid.is_some()&&pid==r.pid}

impl ClaudeHookSessionStore {
    pub fn update_last_permission_mode(&self,id:&str,mode:&str)->HookResult<()> {let Some(id)=normalize(Some(id))else{return Ok(())};let Some(mode)=normalize(Some(mode))else{return Ok(())};self.mutate(|s|{if let Some(r)=s.sessions.get_mut(&id){r.last_permission_mode=Some(mode)}Ok(())})}
    pub fn clear_agent_lifecycle_if_present(&self,id:&str)->HookResult<()> {self.mutate(|s|{if let Some(r)=s.sessions.get_mut(id.trim()){r.agent_lifecycle=Some("unknown".into());r.updated_at=now()}Ok(())})}
    pub fn update_session(&self,id:&str,u:&SessionUpdate,mark_active:bool,turn:Option<&str>,allows_replacement:bool,supersedes_same_process:bool)->HookResult<Vec<ClaudeHookSessionRecord>>{
        let Some(id)=normalize(Some(id))else{return Ok(vec![])};self.mutate(|s|{let time=now();let mut r=make_record(s,&id,u,time);update_record(&mut r,u,time);let superseded=if supersedes_same_process{supersede(s,&id,&r,time)}else{vec![]};s.sessions.insert(id.clone(),r);if mark_active{let active=ClaudeHookActiveSessionRecord{session_id:id.clone(),turn_id:normalize(turn),allows_new_session_replacement:allows_replacement.then_some(true),updated_at:time};if let Some(w)=normalize(Some(&u.workspace_id)){s.active_sessions_by_workspace.insert(w,active.clone());}if let Some(sf)=normalize(Some(&u.surface_id)){s.active_sessions_by_surface.insert(sf,active);}}s.reconcile_pending_index();Ok(superseded)})
    }
    pub fn record_prompt_submit(&self,id:&str,u:&SessionUpdate,turn:Option<&str>,previous_terminal:bool,terminal_ids:&HashSet<String>,messages:&[Value],reject_terminal:bool)->HookResult<PromptSubmitResult>{
        let Some(id)=normalize(Some(id))else{return Ok(PromptSubmitResult::default())};self.mutate(|s|{let time=now();let mut r=make_record(s,&id,u,time);let turn=normalize(turn);if reject_terminal&&turn.as_ref().is_some_and(|t|terminal_stack(&r).contains(t)){return Ok(PromptSubmitResult{stale_terminal_turn:true,nested:false})}update_record(&mut r,u,time);append_messages(&mut r,messages);let legacy=r.active_prompt_depth.unwrap_or(0).max(0);let nested;
            if let Some(turn)=turn{let mut terminal=terminal_stack(&r);terminal.retain(|x|x!=&turn);r.terminal_prompt_turn_ids=(!terminal.is_empty()).then_some(terminal);let mut stack=active_stack(&r);if stack.is_empty()&&legacy>0{r.active_prompt_depth=Some(legacy+1);r.active_prompt_turn_id=None;r.active_prompt_turn_ids=None;nested=true;}else if stack.last().is_some_and(|last|last!=&turn){let mut removed=vec![];if previous_terminal{removed.push(stack.pop().unwrap());while stack.last().is_some_and(|t|terminal_ids.contains(t)){removed.push(stack.pop().unwrap());}}let depth=(legacy.max((stack.len()+removed.len()) as i64)-removed.len() as i64).max(0)+1;stack.push(turn.clone());set_active_stack(&mut r,stack,depth);for t in removed{mark_terminal(&mut r,&t);}nested=depth>1;}else if stack.last()==Some(&turn){let depth=legacy.max(stack.len() as i64);set_active_stack(&mut r,stack,depth);nested=depth>1;}else{let depth=legacy.max(stack.len() as i64)+1;stack.push(turn.clone());set_active_stack(&mut r,stack,depth);nested=depth>1;}r.last_prompt_turn_id=Some(turn);}else{let depth=legacy.max(active_stack(&r).len() as i64)+1;r.active_prompt_depth=Some(depth);nested=depth>1;}s.sessions.insert(id,r);Ok(PromptSubmitResult{stale_terminal_turn:false,nested})})
    }
    pub fn record_prompt_stop(&self,id:&str,u:&SessionUpdate,turn:Option<&str>,terminal_ids:&HashSet<String>,messages:&[Value])->HookResult<bool>{
        let Some(id)=normalize(Some(id))else{return Ok(false)};self.mutate(|s|{let time=now();let mut r=make_record(s,&id,u,time);let before=r.active_prompt_depth.unwrap_or(0).max(0);let after=(before-1).max(0);let mut update=u.clone();if after!=0{update.agent_lifecycle=Some("running".into())}update_record(&mut r,&update,time);append_messages(&mut r,messages);
            let nested=if let Some(turn)=normalize(turn){let mut stack=active_stack(&r);let mut total=before.max(stack.len() as i64);let mut removed=vec![];stack.retain(|t|{if t!=&turn&&terminal_ids.contains(t){removed.push(t.clone());false}else{true}});if !removed.is_empty(){total=(total-removed.len() as i64).max(0);set_active_stack(&mut r,stack.clone(),total);for t in removed{mark_terminal(&mut r,&t)}}
                if let Some(last)=stack.last(){if last==&turn{stack.pop();set_active_stack(&mut r,stack,(total-1).max(0));mark_terminal(&mut r,&turn);total>1}else{if let Some(index)=stack.iter().rposition(|t|t==&turn){stack.remove(index);set_active_stack(&mut r,stack,(total-1).max(0));mark_terminal(&mut r,&turn);}else if before>stack.len() as i64{set_active_stack(&mut r,stack,(before-1).max(0));mark_terminal(&mut r,&turn);}true}}
                else if total==0&&terminal_stack(&r).contains(&turn){true}else{mark_terminal(&mut r,&turn);if total>0{set_active_stack(&mut r,vec![],(total-1).max(0));}total>1}
            }else{if after==0{set_active_stack(&mut r,vec![],0)}else{let mut stack=active_stack(&r);if !stack.is_empty(){stack.truncate(after as usize);set_active_stack(&mut r,stack,after)}else{r.active_prompt_depth=Some(after)}}before>1};s.sessions.insert(id,r);Ok(nested)})
    }
    pub fn upsert_authoritative_claude_session_start(&self,id:&str,source:Option<&str>,u:&SessionUpdate,turn:Option<&str>)->HookResult<bool>{let Some(id)=normalize(Some(id))else{return Ok(false)};let Some(w)=normalize(Some(&u.workspace_id))else{return Ok(false)};let Some(sf)=normalize(Some(&u.surface_id))else{return Ok(false)};self.mutate(|s|{let active=s.active_sessions_by_surface.get(&sf);let newer=active.and_then(|a|s.sessions.get(&a.session_id)).is_some_and(|r|authoritative_newer(u.pid,r));let accepts=normalize(source).is_some_and(|x|x.eq_ignore_ascii_case("clear"))||active.is_none()||active.is_some_and(|a|a.session_id==id)||!s.sessions.contains_key(&id)||active.is_some_and(|a|a.allows_new_session_replacement==Some(true))||newer;if !accepts{return Ok(false)}let time=now();let mut update=u.clone();update.workspace_id=w.clone();update.surface_id=sf.clone();update.is_restorable=Some(false);update.agent_lifecycle=Some("running".into());let mut r=make_record(s,&id,&update,time);update_record(&mut r,&update,time);s.sessions.insert(id.clone(),r);s.active_sessions_by_workspace.retain(|key,a|key==&w||a.session_id!=id);s.active_sessions_by_surface.retain(|key,a|key==&sf||a.session_id!=id);let a=ClaudeHookActiveSessionRecord{session_id:id,turn_id:normalize(turn),allows_new_session_replacement:None,updated_at:time};s.active_sessions_by_workspace.insert(w,a.clone());s.active_sessions_by_surface.insert(sf,a);Ok(true)})}
    pub fn upsert_codex_session_start_if_fresh(&self,id:&str,u:&SessionUpdate)->HookResult<bool>{let Some(id)=normalize(Some(id))else{return Ok(false)};self.mutate(|s|{let time=now();let mut r=make_record(s,&id,u,time);if stale_start(&r,u.pid,true){return Ok(false)}set_active_stack(&mut r,vec![],0);r.last_prompt_turn_id=None;update_record(&mut r,u,time);s.sessions.insert(id,r);Ok(true)})}
    pub fn upsert_codex_prompt_running_if_fresh(&self,id:&str,u:&SessionUpdate,turn:Option<&str>)->HookResult<bool>{let Some(id)=normalize(Some(id))else{return Ok(false)};self.mutate(|s|{let time=now();let mut r=make_record(s,&id,u,time);if normalize(turn).is_some_and(|t|terminal_stack(&r).contains(&t)){return Ok(false)}let mut u=u.clone();u.agent_lifecycle=Some("running".into());u.runtime_status=Some("running".into());u.update_runtime_status=true;update_record(&mut r,&u,time);s.sessions.insert(id,r);Ok(true)})}
    pub fn codex_session_start_is_stale(&self,id:&str,pid:Option<i64>,include_terminal:bool)->HookResult<bool>{Ok(self.lookup(id)?.is_some_and(|r|stale_start(&r,pid,include_terminal)))}
    pub fn codex_prompt_turn_is_terminal(&self,id:&str,turn:Option<&str>)->HookResult<bool>{let Some(turn)=normalize(turn)else{return Ok(false)};Ok(self.lookup(id)?.is_some_and(|r|terminal_stack(&r).contains(&turn)))}
    pub fn mark_notification_resolved(&self,id:&str,u:&SessionUpdate)->HookResult<()>{let Some(id)=normalize(Some(id))else{return Ok(())};self.mutate(|s|{let time=now();let mut r=make_record(s,&id,u,time);let mut u=u.clone();u.update_last_notification_status=true;u.last_notification_status=None;u.update_runtime_status=u.runtime_status.is_some();update_record(&mut r,&u,time);r.last_subtitle=None;r.last_body=None;r.last_notification_status=None;s.sessions.insert(id,r);Ok(())})}
}
fn authoritative_newer(pid:Option<i64>,r:&ClaudeHookSessionRecord)->bool{let Some(pid)=pid else{return false};let Some(incoming)=process::claude_process_start_identity(pid)else{return false};if let Some(stored)=r.pid_start_seconds.zip(r.pid_start_microseconds){incoming>stored}else{r.pid.is_some_and(|p|p!=pid&&!process::process_exists(Some(p)))}}
