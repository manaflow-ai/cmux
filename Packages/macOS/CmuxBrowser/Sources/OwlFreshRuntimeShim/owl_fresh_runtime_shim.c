#include "owl_fresh_runtime_shim.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
struct OwlShimSession { void *raw; OwlShimCallback callback; void *user_data; };
typedef int (*fn_global_init)(void);
typedef OwlShimSession *(*fn_create)(const char*,const char*,const char*,OwlShimCallback,void*);
typedef void (*fn_destroy)(OwlShimSession*);
typedef int32_t (*fn_host_pid)(OwlShimSession*);
typedef int (*fn_bind)(OwlShimSession*,uint64_t,char**);
typedef int (*fn_nav)(OwlShimSession*,const char*,char**);
typedef int (*fn_resize)(OwlShimSession*,uint32_t,uint32_t,float,char**);
typedef int (*fn_focus)(OwlShimSession*,bool,char**);
typedef int (*fn_mouse)(OwlShimSession*,uint32_t,float,float,uint32_t,uint32_t,float,float,uint32_t,char**);
typedef int (*fn_key)(OwlShimSession*,bool,uint32_t,const char*,uint32_t,char**);
typedef int (*fn_eval)(OwlShimSession*,const char*,char**,char**);
typedef int (*fn_surface)(OwlShimSession*,char**,char**);
typedef int (*fn_capture_surface)(OwlShimSession*,char**,char**);
typedef void (*fn_poll)(uint32_t);
typedef void (*fn_free)(void*);
static void *handle; static fn_global_init global_init; static fn_create create_fn; static fn_destroy destroy_fn; static fn_host_pid host_pid; static fn_bind set_client,b_profile,b_web,b_input,b_surface,b_native; static fn_nav nav_fn; static fn_resize resize_fn; static fn_focus focus_fn; static fn_mouse mouse_fn; static fn_key key_fn; static fn_eval eval_fn; static fn_surface surface_fn; static fn_capture_surface capture_surface_fn; static fn_poll poll_fn; static fn_free free_fn;
#define LOAD(var, type, symbol) do { *(void **)(&(var)) = dlsym(handle, symbol); } while (0)
int owl_shim_open(const char *path) { if(handle) return 0; handle=dlopen(path,RTLD_LOCAL|RTLD_NOW); if(!handle)return -1; LOAD(global_init,fn_global_init,"owl_fresh_mojo_global_init"); LOAD(create_fn,fn_create,"owl_fresh_mojo_session_create"); LOAD(destroy_fn,fn_destroy,"owl_fresh_mojo_session_destroy"); LOAD(host_pid,fn_host_pid,"owl_fresh_mojo_session_host_pid"); LOAD(set_client,fn_bind,"owl_fresh_mojo_session_set_client"); LOAD(b_profile,fn_bind,"owl_fresh_mojo_session_bind_profile"); LOAD(b_web,fn_bind,"owl_fresh_mojo_session_bind_web_view"); LOAD(b_input,fn_bind,"owl_fresh_mojo_session_bind_input"); LOAD(b_surface,fn_bind,"owl_fresh_mojo_session_bind_surface_tree"); LOAD(b_native,fn_bind,"owl_fresh_mojo_session_bind_native_surface_host"); LOAD(nav_fn,fn_nav,"owl_fresh_mojo_web_view_navigate"); LOAD(resize_fn,fn_resize,"owl_fresh_mojo_web_view_resize"); LOAD(focus_fn,fn_focus,"owl_fresh_mojo_web_view_set_focus"); LOAD(mouse_fn,fn_mouse,"owl_fresh_mojo_input_send_mouse"); LOAD(key_fn,fn_key,"owl_fresh_mojo_input_send_key"); LOAD(eval_fn,fn_eval,"owl_fresh_mojo_shell_execute_javascript"); LOAD(surface_fn,fn_surface,"owl_fresh_mojo_surface_tree_get_json"); LOAD(capture_surface_fn,fn_capture_surface,"owl_fresh_mojo_surface_tree_capture_surface_json"); LOAD(poll_fn,fn_poll,"owl_fresh_mojo_poll_events"); LOAD(free_fn,fn_free,"owl_fresh_mojo_free_buffer"); return global_init&&create_fn&&destroy_fn&&host_pid&&set_client&&b_profile&&b_web&&b_input&&b_surface&&b_native&&nav_fn&&resize_fn&&focus_fn&&mouse_fn&&key_fn&&poll_fn?0:-2; }
void owl_shim_close(void){if(handle){dlclose(handle);handle=NULL;}}
int owl_shim_global_init(void){return global_init?global_init():-1;}
OwlShimSession *owl_shim_session_create(const char *shell,const char *url,const char *profile,OwlShimCallback cb,void *ud){return create_fn?create_fn(shell,url,profile,cb,ud):NULL;}
void owl_shim_session_destroy(OwlShimSession *s){if(destroy_fn&&s)destroy_fn(s);}
int32_t owl_shim_session_host_pid(OwlShimSession *s){return host_pid&&s?host_pid(s):-1;}
static int callbind(fn_bind f,OwlShimSession*s,uint64_t h){char*e=NULL;int r=f?f(s,h,&e):-1;if(e&&free_fn)free_fn(e);return r;}
int owl_shim_bind_all(OwlShimSession*s){return callbind(set_client,s,1)||callbind(b_profile,s,2)||callbind(b_web,s,3)||callbind(b_input,s,4)||callbind(b_surface,s,5)||callbind(b_native,s,6);}
#define CALL1(f,...) do{char*e=NULL;int r=f?f(__VA_ARGS__,&e):-1;if(e&&free_fn)free_fn(e);return r;}while(0)
int owl_shim_navigate(OwlShimSession*s,const char*u){CALL1(nav_fn,s,u);} int owl_shim_resize(OwlShimSession*s,uint32_t w,uint32_t h,float x){CALL1(resize_fn,s,w,h,x);} int owl_shim_focus(OwlShimSession*s,bool f){CALL1(focus_fn,s,f);} int owl_shim_mouse(OwlShimSession*s,uint32_t k,float x,float y,uint32_t b,uint32_t c,float dx,float dy,uint32_t m){CALL1(mouse_fn,s,k,x,y,b,c,dx,dy,m);} int owl_shim_key(OwlShimSession*s,bool d,uint32_t k,const char*t,uint32_t m){CALL1(key_fn,s,d,k,t,m);}
int owl_shim_eval(OwlShimSession*s,const char*script,char**out){char*e=NULL;int r=eval_fn?eval_fn(s,script,out,&e):-1;if(e&&free_fn)free_fn(e);return r;} int owl_shim_surface_json(OwlShimSession*s,char**out){char*e=NULL;int r=surface_fn?surface_fn(s,out,&e):-1;if(e&&free_fn)free_fn(e);return r;} int owl_shim_capture_surface_json(OwlShimSession*s,char**out){char*e=NULL;int r=capture_surface_fn?capture_surface_fn(s,out,&e):-1;if(e&&free_fn)free_fn(e);return r;} void owl_shim_free(void*p){if(p&&free_fn)free_fn(p);} void owl_shim_poll(uint32_t t){if(poll_fn)poll_fn(t);}
